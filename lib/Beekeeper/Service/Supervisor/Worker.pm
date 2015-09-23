package Beekeeper::Service::Supervisor::Worker;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Service::Supervisor::Worker - Worker pool supervisor.

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

Track state of workers.

=head1 TODO:

- Security

=cut

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Beekeeper::Worker::Util 'shared_hash';

use constant CHECK_PERIOD => 5; #TODO: should be 20 or something


sub on_startup {
    my $self = shift;

    $self->{host} = $self->{_WORKER}->{hostname};
    $self->{pool} = $self->{_WORKER}->{pool_id};

    $self->{Workers} = $self->shared_hash( name => "workers-status" );
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

    #
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
It contains also statistical data about worker performance.

Note that workers doing long jobs may not call this method timely.

=cut

sub worker_status {
    my ($self, $params) = @_;

    $self->set_worker_status( %$params );
}

=item on_worker_exit

Handler for 'supervisor.worker_exit' job.

This job is sent by workers just before exiting gracefully.
It is not sent if worker is terminated abruptly, as it has no chance to do so. 

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


=pod

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

            next if ($worker->{msize} && $worker->{msize} eq $msize);

            $self->set_worker_status(
                pool  => $worker->{pool},
                host  => $worker->{host},
                pid   => $worker->{pid},
                msize => $msize,
            );
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

=pod

# If queue is empty, activate Rejector/Sinkhole/Drainer

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

    # Do not drain SharedHash synchronization queue
    @unserviced = grep { $_ !~ m/^_sync\.shared-/ } @unserviced;

    return unless @unserviced;

    # Tell sinkhole service to drain...
    $self->send_notification(
        method => '_bkpr.sinkhole.unserviced_queues',
        params => { queues => \@unserviced },
    );
}

=item get_workers_status

Handler for 'supervisor.get_workers_status' job.

Used by monitor command line tool.

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

Used by monitor command line tool.

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

This notification is sent by restart-workers command line tool.

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
            kill( 'INT', $pid );
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
                    kill( 'INT', $pid );
                },
            );
        }
    }
}


=item restart_pool

Handler for 'supervisor.restart_pool' notification.

This notification is sent by restart-pool command line tool.

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

    # Sort all pools by name, then return the index of the requested one

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
