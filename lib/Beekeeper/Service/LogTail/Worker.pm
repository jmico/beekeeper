package Beekeeper::Service::LogTail::Worker;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Service::LogTail::Worker - Buffer log entries

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

By default all workers use a C<Beekeeper::Logger> logger which logs errors and
warnings both to files and to a topic C</topic/log> on the message bus.

This worker keeps an in memory buffer of every log entry sent to that topic in
every broker in a logical message bus.

=head1 METHODS

=head3 tail ( %filters )

Returns all buffered entries that match the filter criteria.

=cut

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use JSON::XS;
use Scalar::Util 'weaken';

my @Log_buffer;


sub authorize_request {
    my ($self, $req) = @_;

    return unless $req->has_auth_tokens('BKPR_ADMIN');

    return REQUEST_AUTHORIZED;
}

sub on_startup {
    my $self = shift;

    $self->{max_size} = $self->{config}->{max_size} || 1000;

    $self->_connect_to_all_brokers;

    $self->accept_jobs(
        '_bkpr.logtail.tail' => 'tail',
    );
}

sub _connect_to_all_brokers {
    my $self = shift;
    weaken($self);

    my $own_bus = $self->{_BUS};
    my $cluster_config = Beekeeper::Config->get_cluster_config( bus_id => $own_bus->bus_id );

    $self->{_CLUSTER} = [];

    foreach my $config (@$cluster_config) {

        my $bus_id = $config->{'bus-id'};

        if ($bus_id eq $own_bus->bus_id) {
            # Already connected to our own bus
            $self->_collect_log($own_bus);
            next;
        }

        my $bus; $bus = Beekeeper::Bus::STOMP->new( 
            %$config,
            bus_id     => $bus_id,
            timeout    => 300,
            on_connect => sub {
                # Setup subscriptions
                $self->_collect_log($bus);
            },
            on_error => sub {
                # Reconnect
                my $errmsg = $_[0] || ""; $errmsg =~ s/\s+/ /sg;
                log_error "Connection to $bus_id failed: $errmsg";
                my $delay = $self->{connect_err}->{$bus_id}++;
                $self->{reconnect_tmr}->{$bus_id} = AnyEvent->timer(
                    after => ($delay < 10 ? $delay * 3 : 30),
                    cb    => sub { $bus->connect },
                );
            },
        );

        push @{$self->{_CLUSTER}}, $bus;

        $bus->connect;
    }
}

sub _collect_log {
    my ($self, $bus) = @_;
    weaken($self);

    # Default logger logs to topics /topic/log.$level.$service

    $bus->subscribe(
        destination    => "/topic/log.#",
        on_receive_msg => sub {
            my ($body_ref, $msg_headers) = @_;

            my $req = decode_json($$body_ref);

            $req->{params}->{type} = $req->{method};

            push @Log_buffer, $req->{params};

            shift @Log_buffer if (@Log_buffer >= $self->{max_size});

            $self->{notif_count}++;
        }
    );
}

sub on_shutdown {
    my ($self, %args) = @_;

     foreach my $bus (@{$self->{_CLUSTER}}) {

        next unless ($bus->{is_connected});
        $bus->disconnect( blocking => 1 );
    }
}

sub tail {
    my ($self, $params) = @_;

    foreach ('count','level','after') {
        next unless defined $params->{$_};
        unless ($params->{$_} =~ m/^\d+(\.\d+)?$/) {
            die "Invalid parameter $_";
        }
    }

    foreach ('host','pool','service','message') {
        next unless defined $params->{$_};
        # Allow simple regexes
        unless ($params->{$_} =~ m/^[\w .*+?:,()\-\[\]\\]+$/) {
            die "Invalid parameter $_";
        }
    }

    my $count = $params->{count} || 10;
    my $after = $params->{after};
    my $level = $params->{level};

    # This will die when an invalid regex is provided, but that's fine
    my $host_re = defined $params->{host}    ? qr/$params->{host}/i    : undef;
    my $pool_re = defined $params->{pool}    ? qr/$params->{pool}/i    : undef;
    my $svc_re  = defined $params->{service} ? qr/$params->{service}/i : undef;
    my $msg_re  = defined $params->{message} ? qr/$params->{message}/i : undef;

    my ($entry, @filtered);

    for (my $i = @Log_buffer - 1; $i >= 0; $i--) {

        $entry = $Log_buffer[$i];

        next if (defined $level   && $entry->{level}    > $level   ) || 
                (defined $after   && $entry->{tstamp}  <= $after   ) ||
                (defined $host_re && $entry->{host}    !~ $host_re ) ||
                (defined $pool_re && $entry->{pool}    !~ $pool_re ) ||
                (defined $svc_re  && $entry->{service} !~ $svc_re  ) ||
                (defined $msg_re  && $entry->{message} !~ $msg_re  );

        unshift @filtered, $entry;

        last if (@filtered >= $count);
    }

    return \@filtered;
}

1;

=head1 AUTHOR

José Micó, C<jose.mico@gmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2015 José Micó.

This is free software; you can redistribute it and/or modify it under the same 
terms as the Perl 5 programming language itself.

This software is distributed in the hope that it will be useful, but it is 
provided “as is” and without any express or implied warranties. For details, 
see the full text of the license in the file LICENSE.

=cut
