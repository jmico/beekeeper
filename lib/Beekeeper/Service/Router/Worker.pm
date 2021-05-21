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
use Scalar::Util 'weaken';

use constant SESSION_TIMEOUT => 1800;
use constant SHUTDOWN_WAIT   => 2;
use constant QUEUE_LANES     => 2;
use constant DEBUG           => 0;

$Beekeeper::Worker::LogLevel = 9 if DEBUG;


sub authorize_request {
    my ($self, $req) = @_;

    return unless $req->has_auth_tokens('BKPR_ROUTER');

    return REQUEST_AUTHORIZED;
}

sub on_startup {
    my $self = shift;

    log_info "Router started";

    my $backend_bus = $self->{_BUS};
    my $backend_id  = $backend_bus->bus_id;
    log_debug "Connected to backend bus \@$backend_id";

    $self->_init_routing_table;

    my $worker_config = $self->{_WORKER}->{config};
    my $bus_config    = $self->{_WORKER}->{bus_config};

    # Determine name of frontend cluster
    my $frontend_cluster = $worker_config->{'frontend_cluster'} || 'frontend';
    $self->{frontend_cluster} = $frontend_cluster;

    my $frontends_config = Beekeeper::Config->get_cluster_config( cluster => $frontend_cluster );

    unless (@$frontends_config) {
        die "No bus in cluster '$frontend_cluster' found into config file bus.config.json\n";
    }

    $self->{wait_frontends_up} = AnyEvent->condvar;

    # Create a connection to every frontend
    foreach my $config (@$frontends_config) {

        # Connect to frontend using backend user and pass 
        $config->{'username'} = $self->{_BUS}->{config}->{username};
        $config->{'password'} = $self->{_BUS}->{config}->{password};

        $self->init_frontend_connection( $config );
    }
}

sub init_frontend_connection {
    my ($self, $config) = @_;

    my $bus_id = $config->{'bus-id'};

    $self->{wait_frontends_up}->begin;

    my $bus; $bus = Beekeeper::MQTT->new( 
        %$config,
        bus_id   => $bus_id,
        timeout  => 60,
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

    $bus->connect(
        on_connack => sub {
            # Setup routing
            log_debug "Connected to frontend bus \@$bus_id";
            $self->{FRONTEND}->{$bus_id} = $bus;
            $self->{wait_frontends_up}->end;
            $self->pull_frontend_requests( frontend => $bus );
            $self->pull_backend_responses( frontend => $bus );
            $self->pull_backend_notifications( frontend => $bus );
        },
    );
}

sub on_shutdown {
    my ($self, %args) = @_;

    $self->stop_accepting_jobs('_bkpr.router.*');

    my $frontend_cluster = $self->{frontend_cluster};

    my $backend_bus     = $self->{_BUS};
    my $backend_cluster = $self->{_BUS}->{cluster};

    my $cv = AnyEvent->condvar;

    # 1. Do not pull frontend requests anymore
    foreach my $frontend_bus (values %{$self->{FRONTEND}}) {

        foreach my $lane (1..QUEUE_LANES) {

            $cv->begin;
            $frontend_bus->unsubscribe(
              # destination => "/queue/req.$backend_cluster-$lane",
                topic        => "\$share/BKPR/req/$backend_cluster-$lane",
                on_unsuback  => sub { $cv->end },
            );
        }
    }

    # 2. Stop forwarding notifications to frontend
    foreach my $lane (1..QUEUE_LANES) {

        $cv->begin;
        $backend_bus->unsubscribe(
          # destination => "/queue/msg.$frontend_cluster-$lane",
            topic        => "\$share/BKPR/msg/$frontend_cluster-$lane",
            on_unsuback  => sub { $cv->end },
        );
    }

    # 3. Wait for unsubscribe receipts, assuring that no more requests or messages are buffered 
    my $tmr = AnyEvent->timer( after => 30, cb => sub { $cv->send });
    $cv->recv;

    # 4. Just in case of pool stop, wait for workers to finish their current jobs
    my $wait = AnyEvent->condvar;
    $tmr = AnyEvent->timer( after => SHUTDOWN_WAIT, cb => sub { $wait->send });
    $wait->recv;

    # 5. Stop forwarding responses to frontend
    foreach my $frontend_bus (values %{$self->{FRONTEND}}) {

        my $frontend_id = $frontend_bus->bus_id;

        foreach my $lane (1..QUEUE_LANES) {

            $cv->begin;
            $backend_bus->unsubscribe(
              # destination => "/queue/res.$frontend_id-$lane",
                topic       => "\$share/BKPR/res/$frontend_id-$lane",
                on_unsuback => sub { $cv->end },
            );
        }
    }

    # 6. Wait for unsubscribe receipts, assuring that no more responses are buffered 
    $tmr = AnyEvent->timer( after => 30, cb => sub { $cv->send });
    $cv->recv;
 
    # Disconnect from all frontends
    my @frontends = values %{$self->{FRONTEND}};
    foreach my $frontend_bus (@frontends) {

        next unless ($frontend_bus->{is_connected});
        $frontend_bus->disconnect;
    }

    # Disconnect from backend cluster
    $self->{Sessions}->disconnect;
}

sub pull_frontend_requests {
    my ($self, %args) = @_;
    weaken($self);

    # Get requests from frontend bus and forward them to backend bus
    #
    # from:  req/backend-n                @frontend
    # to:    req/backend/{app}/{service}  @backend

    my $frontend_bus = $args{frontend};
    my $frontend_id  = $frontend_bus->bus_id;

    my $backend_bus     = $self->{_BUS};
    my $backend_id      = $backend_bus->bus_id;
    my $backend_cluster = $backend_bus->cluster;

    foreach my $lane (1..QUEUE_LANES) {

        my $src_queue = "\$share/BKPR/req/$backend_cluster-$lane";

        my ($payload_ref, $msg_prop);
        my ($dest_queue, $reply_to, $session_id, $session);
        my %pub_args;

        $frontend_bus->subscribe(
            topic       => $src_queue,
            maximum_qos => 0,
            on_publish  => sub {
                ($payload_ref, $msg_prop) = @_;

                # (!) UNTRUSTED REQUEST

                # eg: req/backend/myapp/service
                $dest_queue = $msg_prop->{'fwd_to'} || '';
                return unless $dest_queue =~ m|^req(/(?!_)[\w-]+)+$|;

                # eg: priv/7nXDsxMDwgLUSedX@frontend-1
                $reply_to = $msg_prop->{'response_topic'} || '';
                return unless $reply_to =~ m|^priv/(\w{16,22})$|;
                $session_id = $1;

                #TODO: Extra sanity checks could be done here before forwarding to backend

                %pub_args = (
                    topic          => $dest_queue,
                   'x-session'     => $session_id,
                    response_topic => "res/$frontend_id-$lane",
                    fwd_reply      => "$reply_to\@$frontend_id",
                    payload        => $payload_ref,
                    qos            => 1, # because workers consume using QoS 1
                );

                $session = $self->{Sessions}->get( $session_id );

                if (defined $session) {
                    $self->{Sessions}->touch( $session_id );
                    $pub_args{'x-auth-tokens'} = $session->[2];
                }

                if (exists $msg_prop->{'message_expiry'}) {
                    $pub_args{'message_expiry'} = $msg_prop->{'message_expiry'};
                }

                $backend_bus->publish( %pub_args );

                DEBUG && log_trace "Forwarded request:  $src_queue \@$frontend_id --> $dest_queue \@$backend_id";

                $self->{_WORKER}->{jobs_count}++;
            },
            on_suback => sub {
                log_debug "Forwarding $src_queue \@$frontend_id --> req/$backend_cluster/{app}/{service} \@$backend_id";
            },
        );
    }
}

sub pull_backend_responses {
    my ($self, %args) = @_;

    # Get responses from backend bus and forward them to frontend bus
    #
    # from:  res/frontend-n     @backend
    # to:    priv/{session_id}  @frontend

    my $frontend_bus = $args{frontend};
    my $frontend_id  = $frontend_bus->bus_id;

    my $backend_bus  = $self->{_BUS};
    my $backend_id   = $backend_bus->bus_id;

    foreach my $lane (1..QUEUE_LANES) {

        my $src_queue = "\$share/BKPR/res/$frontend_id-$lane";

        my ($payload_ref, $msg_prop, $dest_queue);

        $backend_bus->subscribe(
            topic       => $src_queue,
            maximum_qos => 0,
            on_publish  => sub {
                ($payload_ref, $msg_prop) = @_;

                ($dest_queue) = split('@', $msg_prop->{'fwd_reply'}, 2);

                $frontend_bus->publish(
                    topic   => $dest_queue,
                    payload => $payload_ref,
                );

                DEBUG && log_trace "Forwarded response: $src_queue \@$backend_id --> $dest_queue \@$frontend_id";
            },
            on_suback => sub {
                log_debug "Forwarding $src_queue \@$backend_id --> priv/{session_id} \@$frontend_id";
            },
        );
    }
}

sub pull_backend_notifications {
    my ($self, %args) = @_;
    weaken($self);

    # Get notifications from backend bus and broadcast them to all frontend buses
    #
    # from:  msg/frontend-n                @backend
    # to:    msg/{app}/{service}/{method}  @frontend

    unless (keys %{$self->{FRONTEND}} && $self->{wait_frontends_up}->ready) {
        # Wait until connected to all (working) frontends before pulling 
        # notifications otherwise messages cannot be broadcasted properly
        #TODO: MQTT: broker will discard messages unless someone subscribes
        return;
    }

    my $frontend_bus = $args{frontend};
    my $frontend_id  = $frontend_bus->bus_id;

    my $backend_bus  = $self->{_BUS};
    my $backend_id   = $backend_bus->bus_id;

    my $frontend_cluster = $self->{frontend_cluster};

    foreach my $lane (1..QUEUE_LANES) {

        my $src_queue = "\$share/BKPR/msg/$frontend_cluster-$lane",

        my ($payload_ref, $msg_prop, $destination, $address);

        $backend_bus->subscribe(
            topic       => $src_queue,
            maximum_qos => 0,
            on_publish  => sub {
                ($payload_ref, $msg_prop) = @_;

                ($destination, $address) = split('@', $msg_prop->{'fwd_to'}, 2);

                if (defined $address) {

                    # Unicast
                    my $dest_queues = $self->{Addr_to_queues}->{$address} || return;

                    foreach my $queue (@$dest_queues) {

                        my ($destination, $bus_id) = split('@', $queue, 2);

                        my $frontend_bus = $self->{FRONTEND}->{$bus_id} || next;

                        $frontend_bus->publish(
                            topic   => $destination,
                            payload => $payload_ref,
                        );

                        DEBUG && log_trace "Forwarded notific:  $src_queue \@$backend_id --> $destination \@$frontend_id";
                    }
                }
                else {

                    # Broadcast
                    foreach my $frontend_bus (values %{$self->{FRONTEND}}) {

                        $frontend_bus->publish(
                            topic   => $destination,
                            payload => $payload_ref,
                        );

                        DEBUG && log_trace "Forwarded notific:  $src_queue \@$backend_id --> $destination \@$frontend_id";
                    }
                }

                $self->{_WORKER}->{notif_count}++;
            },
            on_suback => sub {
                log_debug "Forwarding $src_queue \@$backend_id --> msg/{app}/{service}/{method} \@$frontend_id";
            },
        );
    }
}

sub _init_routing_table {
    my $self = shift;

    my $worker_config = $self->{_WORKER}->{config};
    my $sess_timeout = $worker_config->{'session_timeout'} ||  SESSION_TIMEOUT;

    $self->{Addr_to_queues} = {};
    $self->{Addr_to_session} = {};

    $self->{Sessions} = $self->shared_cache( 
        id => "router",
        persist => 1,
        max_age => $sess_timeout,
        on_update => sub {
            my ($session, $value, $old_value) = @_;

            # Keep indexes:  address -> relpy queues
            #                address -> sessions

            if (defined $value) {
                # Bind
                my $addr  = $value->[0];
                my $queue = $value->[1];

                my $dest_queues = $self->{Addr_to_queues}->{$addr} ||= [];
                return if grep { $_ eq $queue } @$dest_queues;
                push @$dest_queues, $queue;

                my $dest_session = $self->{Addr_to_session}->{$addr} ||= [];
                push @$dest_session, $session;
            }
            elsif (defined $old_value) {
                # Unbind
                my $addr  = $old_value->[0];
                my $queue = $old_value->[1];

                my $dest_queues = $self->{Addr_to_queues}->{$addr} || return;
                @$dest_queues = grep { $_ ne $queue } @$dest_queues;
                delete $self->{Addr_to_queues}->{$addr} unless @$dest_queues;

                my $dest_session = $self->{Addr_to_session}->{$addr};
                @$dest_session = grep { $_ ne $session } @$dest_session;
                delete $self->{Addr_to_session}->{$addr} unless @$dest_session;
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

    unless (defined $session_id && $session_id =~ m/^\w{16,}$/) {
        # eg: 7nXDsxMDwgLUSedX
        die ( $session_id ? "Invalid session $session_id" : "Session not specified");
    }

    if (defined $address && $address !~ m/^$frontend_cluster\.[\w-]+$/) {
        # eg: @frontend.user-1234
        die "Invalid address $address";
    }

    if (defined $reply_queue && $reply_queue !~ m!^priv/\w+\@[\w-]+$!) {
        # eg: priv/7nXDsxMDwgLUSedX@frontend-1
        die "Invalid reply queue $reply_queue";
    }

    if ($address xor $reply_queue) {
        die "Both address and reply queue must be specified";
    }

    if (defined $auth_tokens && $auth_tokens =~ m/[\x00\n]/) {
        # eg: TOKEN1|TOKEN2|{"foo":"bar"}
        die "Invalid auth tokens $auth_tokens";
    }

    $address =~ s/^$frontend_cluster\.//;

    $self->{Sessions}->set( $session_id => [ $address, $reply_queue, $auth_tokens ] );

    return 1;
}

sub unbind {
    my ($self, $params) = @_;

    my $session_id = $params->{session_id};
    my $address    = $params->{address};

    my $frontend_cluster = $self->{frontend_cluster};

    if (defined $session_id && $session_id !~ m/^[\w]{16,}$/) {
        # eg: B9LY-y22H8K9RLADnEh0Ww
        die "Invalid session $session_id";
    }

    if (defined $address && $address !~ m/^$frontend_cluster\.[\w-]+$/) {
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

        $address =~ s/^$frontend_cluster\.//;

        my $sessions = $self->{Addr_to_session}->{$address};

        # Make a copy because @$sessions shortens on each delete
        my @sessions = $sessions ? @$sessions : ();

        # Remove all sessions binded to address
        foreach my $session_id (@sessions) {
            $self->{Sessions}->delete( $session_id );
        }
    }

    return 1;
}

1;

=encoding utf8
 
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
