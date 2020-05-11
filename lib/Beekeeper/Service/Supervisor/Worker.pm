package Beekeeper::Service::Supervisor::Worker;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Service::Supervisor::Worker - Worker pool supervisor.

=head1 VERSION

Version 0.01

=head1 DESCRIPTION

A Supervisor worker is created automatically in every worker pool.

It keeps a shared table of the status of every worker connected to a logical 
bus in every broker, routinely checking local workers and keeping track of 
workers periodic performance reports.

=cut

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Beekeeper::Worker::Util 'shared_cache';

use constant CHECK_PERIOD => Beekeeper::Worker::REPORT_STATUS_PERIOD;


sub authorize_request {
    my ($self, $req) = @_;
    my $required;

    if ($req->{method} eq '_bkpr.supervisor.worker_status' ||
        $req->{method} eq '_bkpr.supervisor.worker_exit' ) {
        $required = 'BKPR_SYSTEM';
    }
    else {
        $required = 'BKPR_ADMIN';
    }

    $req->has_auth_tokens($required);
}

sub on_startup {
    my $self = shift;

    $self->{host} = $self->{_WORKER}->{hostname};
    $self->{pool} = $self->{_WORKER}->{pool_id};

    $self->{Workers} = $self->shared_cache( id => "workers", max_age => CHECK_PERIOD * 4 );
    $self->{Queues} = {};

    $self->accept_notifications(
        '_bkpr.supervisor.restart_pool'    => 'restart_pool',
        '_bkpr.supervisor.restart_workers' => 'restart_workers',
    );

    $self->accept_jobs(
        '_bkpr.supervisor.worker_status'       => 'worker_status',
        '_bkpr.supervisor.worker_exit'         => 'worker_exit',
        '_bkpr.supervisor.get_workers_status'  => 'get_workers_status',
        '_bkpr.supervisor.get_services_status' => 'get_services_status',
    );

    $self->{check_status_tmr} = AnyEvent->timer(
        after    => rand(CHECK_PERIOD), 
        interval => CHECK_PERIOD, 
        cb => sub {
            $self->check_workers;
            $self->check_queues;
        },
    );
}

sub log_handler {
    my $self = shift;

    # Use pool's logfile
    $self->SUPER::log_handler( foreground => 1 );
}

=item worker_status

Handler for 'supervisor.worker_status' job.

This job is sent by workers every few seconds and acts as a heart-beat.
It contains statistical data about worker performance.

Note that workers doing long jobs (like slow SQL queries) may not send 
this request timely.

=cut

sub worker_status {
    my ($self, $params) = @_;

    $self->set_worker_status( %$params );
}

=item on_worker_exit

Handler for 'supervisor.worker_exit' job.

This job is sent by workers just before exiting gracefully. It is not sent 
when worker is terminated abruptly (as process has no chance to do so).

=cut

sub worker_exit {
    my ($self, $params) = @_;

    $self->remove_worker_status( %$params );

    # Check for unserviced queues, just in case of worker being the last of its kind
    $self->check_queues;
}


sub set_worker_status {
    my ($self, %args) = @_;

    my $pool = $args{'pool'} || die;
    my $host = $args{'host'} || die;
    my $pid  = $args{'pid'}  || die;

    my $worker_id = "$host:$pool:$pid";

    my $status = $self->{Workers}->get( $worker_id ) || {};

    $status = { %$status, %args };

    $self->{Workers}->set( $worker_id => $status );

    if ($status->{queue}) {
        $self->{Queues}->{$_} = 1 foreach @{$status->{queue}};
    }
}

sub touch_worker_status {
    my ($self, %args) = @_;

    my $pool = $args{'pool'} || die;
    my $host = $args{'host'} || die;
    my $pid  = $args{'pid'}  || die;

    my $worker_id = "$host:$pool:$pid";

    $self->{Workers}->touch( $worker_id );
}

sub remove_worker_status {
    my ($self, %args) = @_;

    my $pool = $args{'pool'} || die;
    my $host = $args{'host'} || die;
    my $pid  = $args{'pid'}  || die;

    my $worker_id = "$host:$pool:$pid";

    $self->{Workers}->delete( $worker_id );
}

sub _get_workers {
    my ($self, %args) = @_;

    my $host  = $args{'host'};
    my $pool  = $args{'pool'};
    my $class = $args{'class'};

    my @workers = grep { defined $_        &&
        (!$host  || $_->{host}  eq $host ) &&
        (!$pool  || $_->{pool}  eq $pool ) &&
        (!$class || $_->{class} eq $class)
    } values %{$self->{Workers}->{data}};

    return \@workers;
}


=item check_workers

Check every worker process in this host (even workers in other pools) to
ensure that they are running, and measure their memory usage.

This is needed as workers with long blocking procedures may not report its 
status timely, and abruptly terminated workers has no chance to report that 
they had exited.

It would be nice to measure CPU usage too.

=cut

sub check_workers {
    my $self = shift;

    my $local_workers = $self->_get_workers( host => $self->{host} );

    foreach my $worker (@$local_workers) {

        next unless defined $worker;

        my $pid = $worker->{pid};

        if (open my $fh, '<', "/proc/$pid/statm") {
            # Linux on intel x86 has a fixed 4KB page size
            my ($VIRT, $RES, $SHARE) = map { $_ * 4 } (split /\s/, scalar <$fh>)[0,1,2];            
            close $fh;

            # Apache::SizeLimit uses $VIRT + $SHARE but that doensn't look useful
            my $msize = $RES - $SHARE;

            my $old_size = $worker->{msize};

            if ($old_size && abs($msize - $old_size) / $old_size < .05) {
                # Avoid sending messages when memory changes are below 5%
                $self->touch_worker_status(
                    pool  => $worker->{pool},
                    host  => $worker->{host},
                    pid   => $worker->{pid},
                );
            }
            else {
                # Update worker memory usage
                $self->set_worker_status(
                    pool  => $worker->{pool},
                    host  => $worker->{host},
                    pid   => $worker->{pid},
                    msize => $msize,
                );
            }
        }
        else {
            # Worker is not running anymore
            $self->remove_worker_status(
                pool => $worker->{pool},
                host => $worker->{host},
                pid  => $worker->{pid},
            );
        }
    }
}

=item check_queues

In the case of all workers of a given service being down, all requests sent to
the service will timeout as no one is serving them. This may cause a serious
disruption in the application, as any other service depending of the broken
one will halt too for the duration of the timeout.

In order to mitigate this situation the Sinkhole service will be notified
when unserviced queues are detected, making it to respond immediately to 
all requests with an error response. Then callers will quickly receive an
error response instead of timing out.

=cut

sub check_queues {
    my $self = shift;

    my $Queues = $self->{Queues};

    $Queues->{$_} = 0 foreach (keys %$Queues);

    # Count how many workers are servicing each queue
    foreach my $worker (values %{$self->{Workers}->{data}}) {
        
        # Skip defunct workers (which are remembered a while)
        next unless defined $worker;

        # Do not count queues being drained by Sinkhole 
        next if ($worker->{class} eq 'Beekeeper::Service::Sinkhole::Worker');

        $Queues->{$_}++ foreach @{$worker->{queue}};
    }

    my @unserviced = grep { $Queues->{$_} == 0 } keys %$Queues;

    return unless @unserviced;

    # Tell Sinkhole to respond immediately to all requests sent to 
    # unserviced queues with a "Method not available" error response

    $self->send_notification(
        method => '_bkpr.sinkhole.unserviced_queues',
        _auth_ => '0,BKPR_SYSTEM',
        params => { queues => \@unserviced },
    );
}

=item get_workers_status

Handler for 'supervisor.get_workers_status' job.

Used by bkpr-top command line tool.

=cut

sub get_workers_status {
    my ($self, $args) = @_;

    my $workers = $self->_get_workers(
        host  => $args->{host},
        pool  => $args->{pool},
        class => $args->{class},
    );

    return $workers;
}

=item get_services_status

Handler for 'supervisor.get_services_status' job.

Used by bkpr-top command line tool.

=cut

sub get_services_status {
    my ($self, $args) = @_;

    my $workers = $self->_get_workers(
        host  => $args->{host},
        pool  => $args->{pool},
        class => $args->{class},
    );

    my %services;

    foreach my $worker (@$workers) {
        $services{$worker->{class}}{count}++;
        $services{$worker->{class}}{jps}  += $worker->{jps};
        $services{$worker->{class}}{nps}  += $worker->{nps};
        $services{$worker->{class}}{load} += $worker->{load};
    }

    foreach my $service (values %services) {
        $service->{jps}  = sprintf("%.2f", $service->{jps});
        $service->{nps}  = sprintf("%.2f", $service->{nps}  / $service->{count});
        $service->{load} = sprintf("%.2f", $service->{load} / $service->{count});
    }

    return \%services;
}

=item restart_workers

Handler for 'supervisor.restart_workers' notification.

This request is sent by bkpr-restart command line tool.

=cut

sub restart_workers {
    my ($self, $args) = @_;

    return if ($args->{host} && $args->{host} ne $self->{host});
    return if ($args->{pool} && $args->{pool} ne $self->{pool});

    my $workers = $self->_get_workers(
        host  => $self->{host},
        pool  => $self->{pool},
        class => $args->{class},
    );

    log_info "Restarting workers" . ($args->{class} ? " $args->{class}..." : "...");

    my @worker_pids;

    foreach my $worker (@$workers) {
        # Do not restart supervisor
        next if ($worker->{class} eq 'Beekeeper::Service::Supervisor::Worker');

        my ($pid) = ($worker->{pid} =~ m/^(\d+)$/);  # untaint
        push @worker_pids, $pid if ($pid);
    }

    if (!$args->{delay}) {
        # Restart all workers at once
        foreach my $pid (@worker_pids) {
            kill( 'TERM', $pid );
        }
    }
    else {
        # Slowly restart all workers
        my $delay = $args->{delay};
        my $count = 0;

        foreach my $pid (@worker_pids) {
            $self->{restart_worker_tmr}->{$pid} = AnyEvent->timer(
                after => $delay * $count++, 
                cb => sub {
                    delete $self->{restart_worker_tmr}->{$pid};
                    kill( 'TERM', $pid );
                },
            );
        }
    }
}

=item restart_pool

Handler for 'supervisor.restart_pool' notification.

This request is sent by bkpr-restart command line tool.

=cut

sub restart_pool {
    my ($self, $args) = @_;

    return if ($args->{host} && $args->{host} ne $self->{host});
    return if ($args->{pool} && $args->{pool} ne $self->{pool});

    my $wpool_pid = $self->{_WORKER}->{parent_pid};
    my $delay = $args->{delay};

    if (!$delay) {
        kill( 'HUP', $wpool_pid );
    }
    else {

        my $index = $self->_get_pool_index( $self->{host}, $self->{pool} );

        $self->{restart_pool_tmr} = AnyEvent->timer(
            after => $delay * $index, 
            cb => sub {
                delete $self->{restart_pool_tmr};
                kill( 'HUP', $wpool_pid );
            },
        );
    }
}

sub _get_pool_index {
    my ($self, $host, $pool) = @_;

    # Sort all pools by name, then return the index of the requested one.
    # Used by restart_pool() to determine restart order across hosts

    my %pools;

    foreach my $worker (values %{$self->{Workers}->{data}}) {
        next unless defined $worker;
        $pools{"$worker->{host}:$worker->{pool}"} = 1;
    }

    return 0 unless $pools{"$host:$pool"};

    my $index = 0;

    foreach my $key (sort keys %pools) {
        last if ($key eq "$host:$pool");
        $index++;
    }

    return $index;
}

1;

=head1 AUTHOR

José Micó, C<< <jose.mico@gmail.com> >>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by José Micó.

This is free software; you can redistribute it and/or modify it under the same 
terms as the Perl 5 programming language itself.

This software is distributed in the hope that it will be useful, but it is 
provided “as is” and without any express or implied warranties. For details, 
see the full text of the license in the file LICENSE.

=cut
