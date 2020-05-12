package Beekeeper::Service::Router::Worker;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME
 
Beekeeper::Service::Router::Worker - Route messages between backend and frontend

=head1 VERSION
 
Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

This worker pulls requests from any frontend brokers and forward them to the 
single backend broker it is connected to. It also pull generated responses from
the backend and forward them to the aproppiate frontend broker which the
client is connected to.

In order to push unicasted notifications it keeps a shared table of client
connections and server side assigned arbitrary addresses.

=cut

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Beekeeper::Worker::Util 'shared_cache';

use constant SESSION_TIMEOUT => 1800;


sub authorize_request {
    my ($self, $req) = @_;

    $req->has_auth_tokens('BKPR_ROUTER');
}

sub on_startup {
    my $self = shift;

    $self->_init_routing_table;

    my $worker_config = $self->{_WORKER}->{config};
    my $bus_config    = $self->{_WORKER}->{bus_config};
    my @frontends;

    # Determine name of frontend cluster
    $self->{frontend_cluster} = $worker_config->{'frontend_cluster'} || 'frontend';

    foreach my $config (values %$bus_config) {
        next unless $config->{'cluster'} && $config->{'cluster'} eq $self->{frontend_cluster};
        push @frontends, $config;
    }

    unless (@frontends) {
        die "No bus in cluster '$self->{frontend_cluster}' found into config file bus.config.json\n";
    }

    $self->{wait_frontends_up} = AnyEvent->condvar;

    # Create a connection to every frontend
    foreach my $config (@frontends) {

        # Connect to frontend using backend user and pass 
        $config->{'user'} = $self->{_BUS}->{config}->{user};
        $config->{'pass'} = $self->{_BUS}->{config}->{pass};

        $self->init_frontend_connection( $config );
    }
}

sub init_frontend_connection {
    my ($self, $config) = @_;

    my $bus_id = $config->{'bus-id'};

    $self->{wait_frontends_up}->begin;

    my $bus; $bus = Beekeeper::Bus::STOMP->new( 
        %$config,
        bus_id     => $bus_id,
        timeout    => 60,
        on_connect => sub {
            # Setup routing
            log_debug "Connected to $bus_id";
            $self->{FRONTEND}->{$bus_id} = $bus;
            $self->{wait_frontends_up}->end;
            $self->pull_frontend_requests( frontend => $bus );
            $self->pull_backend_responses( frontend => $bus );
            $self->pull_backend_notifications;
        },
        on_error => sub {
            # Reconnect
            my $errmsg = $_[0] || ""; $errmsg =~ s/\s+/ /sg;
            log_alert "Connection to $bus_id failed: $errmsg";
            delete $self->{FRONTEND}->{$bus_id};
            $self->{wait_frontends_up}->end;
            my $delay = $self->{connect_err}->{$bus_id}++;
            $self->{reconnect_tmr}->{$bus_id} = AnyEvent->timer(
                after => ($delay < 10 ? $delay * 3 : 30),
                cb    => sub { $bus->connect },
            );
        },
    );

    $bus->connect;
}

sub on_shutdown {
    my ($self, %args) = @_;

    $self->stop_accepting_jobs('_bkpr.router.*');

    my $frontend_cluster = $self->{frontend_cluster};

    my $backend_bus     = $self->{_BUS};
    my $backend_cluster = $self->{_BUS}->{cluster};

    my $cv = AnyEvent->condvar;
    $cv->begin;

    $backend_bus->unsubscribe(
        destination => "/queue/msg.$frontend_cluster",
        on_success  => sub { $cv->end },
    );

    foreach my $frontend_bus (values %{$self->{FRONTEND}}) {

        $cv->begin;
        $cv->begin;

        my $frontend_id = $frontend_bus->bus_id;

        $backend_bus->unsubscribe(
            destination => "/queue/res.$frontend_id",
            on_success  => sub { $cv->end },
        );

        $frontend_bus->unsubscribe(
            destination => "/queue/req.$backend_cluster",
            on_success  => sub { $cv->end },
        );
    }

    AnyEvent->now_update;

    my $timeout = AnyEvent->timer(
        after => 10,
        cb    => sub { $cv->send },
    );

    $cv->recv;

    foreach my $frontend_bus (values %{$self->{FRONTEND}}) {

        next unless ($frontend_bus->{is_connected});
        $frontend_bus->disconnect( blocking => 1 );
    }
}

sub pull_frontend_requests {
    my ($self, %args) = @_;

    # Get requests from frontend bus and forward them to backend bus
    #
    # src:  frontend /queue/req.backend
    # dest: backend  /queue/req.backend.class

    my $frontend_bus = $args{frontend};
    my $frontend_id  = $frontend_bus->bus_id;

    my $backend_bus     = $self->{_BUS};
    my $backend_id      = $backend_bus->bus_id;
    my $backend_cluster = $backend_bus->cluster;

    my $RabbitMQ = $frontend_bus->{is_rabbitmq};

    my ($body_ref, $msg_headers);

    $frontend_bus->subscribe(
        destination    => "/queue/req.$backend_cluster",
        ack            => 'auto', # means none
        on_receive_msg => sub {
            ($body_ref, $msg_headers) = @_;

            # (!) UNTRUSTED REQUEST

            my $destination = $msg_headers->{'x-forward-to'} || '';
            return unless $destination =~ m|^/queue/req(\.(?!_)[\w-]+)+$|;

            my $reply_to = $msg_headers->{'reply-to'} || '';
            my $session_id;

            if ($RabbitMQ) {
                # RabbitMQ reply-to: /reply-queue/amq.gen-B9LY-y22H8K9RLADnEh0Ww
                return unless $reply_to =~ m|^/reply-queue/amq\.gen-([\w-]{22})$|;
                $session_id = $1;
            }
            else {
                return unless $reply_to =~ m|^/temp-queue/tmp\.([\w-]{8,22})$|;
                $session_id = $1;
            }

            #TODO: Do basic sanity checks (like max size) on $body_ref before forwarding it to backend

            my @opt_headers;

            my $session = $self->{Sessions}->get( $session_id );

            if ($session) {
                $self->{Sessions}->touch( $session_id );
                if ( $session->[2] ) {
                    push @opt_headers, ( 'x-auth-tokens' => $session->[2] );
                }
            }

            my $expiration = $msg_headers->{'expiration'} || '';
            if ($expiration =~ m|^\d+$|) {
                push @opt_headers, ( 'expiration' => $expiration );
            }

            $backend_bus->send(
                'destination'     => $destination,
                'x-session'       => $session_id,
                'reply-to'        => "/queue/res.$frontend_id",
                'x-forward-reply' => "$reply_to\@$frontend_id",
                'body'            => $body_ref,
                 @opt_headers
            );

            $self->{_WORKER}->{jobs_count}++;
        },
    );
}

sub pull_backend_responses {
    my ($self, %args) = @_;

    # Get responses from backend and send them back to frontend

    my $frontend_bus = $args{frontend};
    my $frontend_id  = $frontend_bus->bus_id;

    my $backend_bus  = $self->{_BUS};

    my ($body_ref, $msg_headers, $destination);

    $backend_bus->subscribe(

        destination    => "/queue/res.$frontend_id",
        ack            => 'auto', # means none
        on_receive_msg => sub {
            ($body_ref, $msg_headers) = @_;

            ($destination) = split('@', $msg_headers->{'x-forward-reply'}, 2);

            $frontend_bus->send(
                'destination' => $destination,
                'body'        => $body_ref,
            );
        },
    );
}

sub pull_backend_notifications {
    my ($self, %args) = @_;

    # Get notifications from backend and broadcast them to frontend

    unless (keys %{$self->{FRONTEND}} && $self->{wait_frontends_up}->ready) {
        # Wait until connected to all (working) frontends before pulling 
        # notifications otherwise messages cannot be broadcasted properly
        return;
    }

    my $frontend_bus = $args{frontend};
    my $backend_bus  = $self->{_BUS};

    my $frontend_cluster = $self->{frontend_cluster};

    my ($body_ref, $msg_headers, $destination, $address);

    $backend_bus->subscribe(

        destination    => "/queue/msg.$frontend_cluster",
        ack            => 'auto', # means none
        on_receive_msg => sub {
            ($body_ref, $msg_headers) = @_;

            ($destination, $address) = split('@', $msg_headers->{'x-forward-to'}, 2);

            if (defined $address) {

                # Unicast
                my $dest_queues = $self->{Addr_to_queues}->{$address} || return;

                foreach my $queue (@$dest_queues) {

                    my ($destination, $bus_id) = split('@', $queue, 2);

                    my $frontend_bus = $self->{FRONTEND}->{$bus_id} || next;

                    $frontend_bus->send(
                        'destination' => $destination,
                        'body'        => $body_ref,
                    );
                }
            }
            else {

                # Broadcast
                foreach my $frontend_bus (values %{$self->{FRONTEND}}) {

                    $frontend_bus->send(
                        'destination' => $destination,
                        'body'        => $body_ref,
                    );
                }
            }

            $self->{_WORKER}->{notif_count}++;
        },
    );
}

sub _init_routing_table {
    my $self = shift;

    my $worker_config = $self->{_WORKER}->{config};
    my $sess_timeout = $worker_config->{'session_timeout'} ||  SESSION_TIMEOUT;

    $self->{Addr_to_queues} = {};

    $self->{Sessions} = $self->shared_cache( 
        id => "router",
        persist => 1,
        max_age => $sess_timeout,
        on_update => sub {
            my ($session, $value, $old_value) = @_;

            # Keep an address -> relpy queues index

            if (defined $value) {
                # Bind
                my $addr  = $value->[0];
                my $queue = $value->[1];
                my $dest_queues = $self->{Addr_to_queues}->{$addr} ||= [];
                return if grep { $_ eq $queue } @$dest_queues;
                push @$dest_queues, $queue;
            }
            elsif (defined $old_value) {
                # Unbind
                my $addr  = $old_value->[0];
                my $queue = $old_value->[1];
                my $dest_queues = $self->{Addr_to_queues}->{$addr} || return;
                @$dest_queues = grep { $_ ne $queue } @$dest_queues;
                delete $self->{Addr_to_queues}->{$addr} unless @$dest_queues;
            }
        },
    );

    $self->accept_jobs(
        '_bkpr.router.bind'   => 'bind',
        '_bkpr.router.unbind' => 'unbind',
    );
}

sub bind {
    my ($self, $params) = @_;

    my $session_id  = $params->{session_id};
    my $address     = $params->{address};
    my $reply_queue = $params->{reply_queue};
    my $auth_tokens = $params->{auth_tokens};

    my $frontend_cluster = $self->{frontend_cluster};

    unless (defined $session_id && $session_id =~ m/^[\w-]{8,}$/) {
        # eg: B9LY-y22H8K9RLADnEh0Ww
        die ( $session_id ? "Invalid session $session_id" : "Session not specified");
    }

    if (defined $address && $address !~ m/^\@$frontend_cluster\.[\w-]+$/) {
        # eg: @frontend.user-1234
        die "Invalid address $address";
    }

    if (defined $reply_queue && $reply_queue !~ m!^/(reply|temp)-queue/\w+\.[\w-]+\@[\w-]+$!) {
        # eg: /reply-queue/amq.gen-B9LY-y22H8K9RLADnEh0Ww@frontend-1
        die "Invalid reply queue $reply_queue";
    }

    if ($address xor $reply_queue) {
        die "Both address and reply queue must be specified";
    }

    if (defined $auth_tokens && $auth_tokens !~ m/^[\w-]+(?:,[\w-]+)*$/) {
        # eg: 101,USER
        die "Invalid auth tokens $auth_tokens";
    }

    $address =~ s/^\@$frontend_cluster\.//;

    #TODO: $self->{Sessions}->delete( $session_id )

    $self->{Sessions}->set( $session_id => [ $address, $reply_queue, $auth_tokens ] );

    return 1;
}

sub unbind {
    my ($self, $params) = @_;

    my $session_id = $params->{session_id};
    my $address    = $params->{address};

    my $frontend_cluster = $self->{frontend_cluster};

    if (defined $session_id && $session_id !~ m/^[\w-]{8,}$/) {
        # eg: B9LY-y22H8K9RLADnEh0Ww
        die "Invalid session $session_id";
    }

    if (defined $address && $address !~ m/^\@$frontend_cluster\.[\w-]+$/) {
        # eg: @frontend.user-1234
        die "Invalid address $address";
    }

    unless ($session_id || $address) {
        die "No session nor address were specified";
    }

    if ($session_id) {
        # Remove single session
        $self->{Sessions}->delete( $session_id );
    }

    if ($address) {

        #TODO: Iterating over entire cache as it is not indexed by address

        $address =~ s/^\@$frontend_cluster\.//;

        my $all_sessions = $self->{Sessions}->raw_data;

        # Remove all sessions binded to address
        foreach my $session_id (keys %$all_sessions) {
            next unless ($all_sessions->{$session_id}->[0] eq $address);
            $self->{Sessions}->delete( $session_id );
        }
    }

    return 1;
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
