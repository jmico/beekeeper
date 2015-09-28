package Beekeeper::Service::Router::Worker;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME
 
Beekeeper::Service::Router::Worker - Route messages between buses

=head1 VERSION
 
Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 TODO

- Delay routing until both backend and frontend connections are up.

- Calculate and report worker load.

- GC

=cut

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Beekeeper::Worker::Util 'shared_hash';

use constant BIND_TIMEOUT => 300;


sub on_startup {
    my $self = shift;

    $self->_init_routing_table;

    my $worker_config = $self->{_WORKER}->{config};
    my $bus_config    = $self->{_WORKER}->{bus_config};
    my @frontends;

    $self->{frontend_cluster} = $worker_config->{'frontend_cluster'} || 'frontend';
    $self->{backend_cluster}  = $worker_config->{'backend_cluster'}  || 'backend'; #TODO

    foreach my $config (values %$bus_config) {
        next unless $config->{'cluster'} && $config->{'cluster'} eq $self->{frontend_cluster};
        push @frontends, $config->{'bus-id'};
    }

    unless (@frontends) {
        die "No bus in cluster '$self->{frontend_cluster}' found into config file bus.config.json\n";
    }

    # Create another connection to backend
    $self->init_backend_connection( $self->{_BUS}->bus_id );

    # Create a connection to every frontend
    foreach my $bus_id (@frontends) {
        $self->init_frontend_connection( $bus_id );
    }
}

sub init_backend_connection {
    my ($self, $bus_id) = @_;

    my $bus_config = $self->{_WORKER}->{bus_config}->{$bus_id};
    my $backend_bus;

    $backend_bus = Beekeeper::Bus::STOMP->new( 
        %$bus_config,
        bus_id     => $bus_id,
        timeout    => 60,
        on_connect => sub {
            # Setup routing
            $self->{BACKEND}->{$bus_id} = $backend_bus;
            foreach my $frontend_bus (values %{$self->{FRONTEND}}) {
                $self->setup_routing( backend => $backend_bus, frontend => $frontend_bus );
            }
        },
        on_error => sub {
            # Reconnect
            #TODO: cancel all routing
            #$self->suspend_routing();
            my $errmsg = shift;
            delete $self->{BACKEND}->{$bus_id};
            log_error "Bus $bus_id: $errmsg";
            $self->{"reconnect_$bus_id"} = AnyEvent->timer(
                after => 30,
                cb    => sub { $backend_bus->connect },
            );
        },
    );

    $backend_bus->connect;
}

sub init_frontend_connection {
    my ($self, $bus_id) = @_;

    my $bus_config = $self->{_WORKER}->{bus_config}->{$bus_id};
    my $frontend_bus;

    $frontend_bus = Beekeeper::Bus::STOMP->new( 
        %$bus_config,
        bus_id     => $bus_id,
        timeout    => 60,
        on_connect => sub {
            # Setup routing
            $self->{FRONTEND}->{$bus_id} = $frontend_bus;
            foreach my $backend_bus (values %{$self->{BACKEND}}) {
                $self->setup_routing( backend => $backend_bus, frontend => $frontend_bus );
            }
        },
        on_error => sub {
            # Reconnect
            #TODO: cancel routing
            my $errmsg = shift;
            delete $self->{FRONTEND}->{$bus_id};
            #$self->suspend_routing();
            log_error "Bus $bus_id: $errmsg";
            $self->{"reconnect_$bus_id"} = AnyEvent->timer(
                after => 30,
                cb    => sub { $frontend_bus->connect },
            );
        },
    );

    $frontend_bus->connect;
}

sub setup_routing {
    my ($self, %args) = @_;

    $self->pull_backend_notifications( %args );
    $self->pull_backend_responses( %args );
    $self->pull_frontend_requests( %args );
}

sub suspend_routing {
    my ($self, %args) = @_;

    #TODO
}

sub pull_frontend_requests {
    my ($self, %args) = @_;

    # Get requests from frontend and forward them to backend

    my $frontend_bus = $args{frontend};
    my $backend_bus  = $args{backend};

    my $frontend_id = $frontend_bus->bus_id;
    my $backend_id  = $backend_bus->bus_id;

    my $backend_cluster  = $self->{backend_cluster};

    my ($body_ref, $msg_headers, $destination, $session_id, $reply_to, $expiration);

    $frontend_bus->subscribe(
        destination    => "/queue/req.$backend_cluster",
        ack            => 'auto', # means none
        on_receive_msg => sub {
            ($body_ref, $msg_headers) = @_;

            # (!) UNTRUSTED REQUEST

            $destination = $msg_headers->{'x-forward-to'} || '';
            return unless $destination =~ m|^/queue/req(\.(?!_)[\w-]+)+$|;
            $destination =~ s|/req\.|/req.$backend_id.|;
            $destination =~ s|\.[\w-]+$||;

            $expiration = $msg_headers->{'expiration'} || 60000;
            return unless $expiration =~ m|^\d+$|;

            # RabbitMQ message-id: T_sub-1@@session-yceVI9Lec0sAg2dyq2gGng@@101
            $session_id = $msg_headers->{'message-id'} || '';
            ($session_id) = ($session_id =~ m|\@\@session-([\w-]{22})\@\@|);
            return unless defined $session_id;

            # RabbitMQ reply-to: /reply-queue/amq.gen-B9LY-y22H8K9RLADnEh0Ww
            $reply_to = $msg_headers->{'reply-to'} || '';
            return unless $reply_to =~ m|^/reply-queue/amq\.gen-[\w-]+$| ||
                          $reply_to =~ m|^/temp-queue/tmp\.[\w-]+$|;

            #TODO: we could check that $body_ref is a valid JSON-RPC request

            $backend_bus->send(
                'destination'     => $destination,
                'x-session-id'    => $session_id,
                'reply-to'        => "/queue/res.$frontend_id",
                'x-forward-reply' => "$reply_to\@$frontend_id",
              # 'content-type'    => $msg_headers->{'content-type'},
                'expiration'      => $expiration,
                'body'            => $body_ref,
            );

            $self->touch("$reply_to\@$frontend_id");
            
            $self->{_WORKER}->{jobs_count}++;
        },
    );
}

sub pull_backend_responses {
    my ($self, %args) = @_;

    # Get responses from backend and send them back to frontend

    my $frontend_bus = $args{frontend};
    my $backend_bus  = $args{backend};

    my $frontend_id = $frontend_bus->bus_id;
    my $backend_id  = $backend_bus->bus_id;

    my ($body_ref, $msg_headers, $destination);

    $backend_bus->subscribe(

        destination    => "/queue/res.$frontend_id",
        ack            => 'auto', # means none
        on_receive_msg => sub {
            ($body_ref, $msg_headers) = @_;

            $destination = $msg_headers->{'x-forward-reply'};
            $destination =~ s/\@([\w-]+)$//;

            $frontend_bus->send(
                'destination'  => $destination,
              # 'content-type' => $msg_headers->{'content-type'},
                'expiration'   => 60000,
                'body'         => $body_ref,
            );
        },
    );
}

sub pull_backend_notifications {
    my ($self, %args) = @_;

    # Get notifications from backend and broadcast them to frontend

return if ($self->{done}); $self->{done} = 1;

    my $frontend_bus = $args{frontend};
    my $backend_bus  = $args{backend};

    my $frontend_cluster = $self->{frontend_cluster};

    my ($body_ref, $msg_headers, $destination);

    $backend_bus->subscribe(

        destination    => "/queue/msg.$frontend_cluster",
        ack            => 'auto', # means none
        on_receive_msg => sub {
            ($body_ref, $msg_headers) = @_;

            $destination = $msg_headers->{'x-forward-to'};

            if ($destination =~ s/\@([\w-]+)$//) {

                # Unicast
                my $addr = $1;
                my $dest_queues = $self->{Addr_to_queues}->{$addr};

                foreach my $aa (@$dest_queues) {

                    my $dest = $aa; #TODO: cleanup
                    $dest =~ s/\@([\w-]+)$//;
                    my $bus_id = $1;

                    my $frontend_bus = $self->{FRONTEND}->{$bus_id} || next;
                    
                    $frontend_bus->send(
                        'destination'  => $dest,
                      # 'content-type' => $msg_headers->{'content-type'},
                        'body'         => $body_ref,
                    );
                }
            }
            else {

                # Broadcast
                foreach my $frontend_bus (values %{$self->{FRONTEND}}) {

                    $frontend_bus->send(
                        'destination'  => $destination,
                      # 'content-type' => $msg_headers->{'content-type'},
                        'body'         => $body_ref,
                    );
                }
            }

            $self->{_WORKER}->{notif_count}++;
        },
    );
}

sub _init_routing_table {
    my $self = shift;

    $self->{Addr_to_queues} = {};

    $self->{Queue_to_addr} = $self->shared_hash( 
        id => "router",
        on_update => sub { 
            my ($queue, $value, $old_value) = @_;

            if (defined $value) {
                # Bind
                my $addr = $value->[1];
                my $dest_queues = $self->{Addr_to_queues}->{$addr} ||= [];
                push @$dest_queues, $queue;
            }
            elsif (defined $old_value) {
                # Unbind
                my $addr = $old_value->[1];
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

    my $address = $params->{addr};
    my $queue   = $params->{queue};

    my $frontend_cluster = $self->{frontend_cluster};
    $address =~ s|\@$frontend_cluster\.([\w-]+)$|$1|; #TODO: or warn...

    $self->{Queue_to_addr}->set( $queue => [ time(), $address ] );
}

sub unbind {
    my ($self, $params) = @_;

    my $queue = $params->{queue};

    $self->{Queue_to_addr}->delete( $queue ); 
}

sub touch {
    my ($self, $queue) = @_;

    my $bind = $self->{Queue_to_addr}->get( $queue );
    my $now = time();

    return unless ($bind && $bind->[0] < $now - BIND_TIMEOUT * .3 );

    $bind->[0] = $now;

    $self->{Queue_to_addr}->set( $queue => $bind );
}

sub gc {
    my $self = shift;

    my $all = $self->{Queue_to_addr}->raw_data;
    my $limit = time() - BIND_TIMEOUT * 1.3;

    foreach my $queue (keys %$all) {
        return unless ($all->{$queue}->[0] && $all->{$queue}->[0] < $limit);
        $self->{Queue_to_addr}->delete( $queue );
    }
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
