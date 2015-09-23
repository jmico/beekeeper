package Beekeeper::Service::Frontend::Worker;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME
 
Beekeeper::Service::Frontend::Worker - Frontend bus message router
 
=head1 VERSION
 
Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 TODO

- Delay routing until both backend and frontend connections are up.

- Calculate and report worker load.

- Ensure that reply queue/topic is private

=cut

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Beekeeper::Worker::Util 'shared_hash';


sub on_startup {
    my $self = shift;

    $self->{Bindings} = $self->shared_hash( 
        name => "bindings",
        on_update => sub { },
    );

    my $worker_config = $self->{_WORKER}->{config};
    my $bus_config    = $self->{_WORKER}->{bus_config};

    my $backend_re  = $worker_config->{'backend_role'}  || 'backend';
    my $frontend_re = $worker_config->{'frontend_role'} || 'frontend';

    my (@backend, @frontend);

    foreach my $bus_id (keys %$bus_config) {

        if ($bus_id =~ m/^$backend_re/) {
            push @backend, $bus_config->{$bus_id};
        }
        elsif ($bus_id =~ m/^$frontend_re/) {
            push @frontend, $bus_config->{$bus_id};
        }
    }

    unless (@backend) {
        die "No bus matching '$backend_re' found into config file bus.config.json\n";
    }

    unless (@frontend) {
        die "No bus matching '$frontend_re' found into config file bus.config.json\n";
    }

    $self->{backend_queue}  = $backend_re;
    $self->{frontend_queue} = $frontend_re;

    foreach my $bus_config (@backend) {
        $self->init_backend_connection( $bus_config );
    }

    foreach my $bus_config (@frontend) {
        $self->init_frontend_connection( $bus_config );
    }
}

sub init_backend_connection {
    my ($self, $bus_config) = @_;

    my $bus_id = $bus_config->{'bus-id'};
    my $bus;

    $bus = Beekeeper::Bus::STOMP->new( 
        %$bus_config,
        bus_id     => $bus_id,
        timeout    => 60,
        on_connect => sub {
            # Setup routing
            $self->{BACKEND}->{$bus_id} = $bus;
            $self->pull_backend_notifications($bus);
            $self->pull_backend_responses($bus);
        },
        on_error => sub {
            # Reconnect
            my $errmsg = shift;
            log_error "Bus $bus_id: $errmsg";
            delete $self->{BACKEND}->{$bus_id};
            $self->{"reconnect_$bus_id"} = AnyEvent->timer(
                after => 30,
                cb    => sub { $bus->connect },
            );
        },
    );

    $bus->connect;
}

sub init_frontend_connection {
    my ($self, $bus_config) = @_;

    my $bus_id = $bus_config->{'bus-id'};
    my $bus;

    $bus = Beekeeper::Bus::STOMP->new( 
        %$bus_config,
        bus_id     => $bus_id,
        timeout    => 60,
        on_connect => sub {
            # Setup routing
            $self->{FRONTEND}->{$bus_id} = $bus;
            $self->pull_frontend_requests($bus);
        },
        on_error => sub {
            # Reconnect
            my $errmsg = shift;
            log_error "Bus $bus_id: $errmsg";
            delete $self->{FRONTEND}->{$bus_id};
            $self->{"reconnect_$bus_id"} = AnyEvent->timer(
                after => 30,
                cb    => sub { $bus->connect },
            );
        },
    );

    $bus->connect;
}


sub pull_frontend_requests {
    my ($self, $frontend_bus) = @_;

    # Get requests from frontend and forward them to backend

    my $backend_queue  = $self->{backend_queue};
    my $frontend_queue = $self->{frontend_queue};
    my $frontend_id    = $frontend_bus->bus_id;

    my ($body_ref, $msg_headers, $destination, $session_id, $reply_to, $expiration);

    $frontend_bus->subscribe(
        destination    => "/queue/req.$backend_queue",
        ack            => 'auto', # means none
        on_receive_msg => sub {
            ($body_ref, $msg_headers) = @_;

            # (!) UNTRUSTED REQUEST

            $destination = $msg_headers->{'x-forward-to'} || '';
            return unless $destination =~ m|^/queue/req(\.(?!_)[\w-]+)+$|;
            $destination =~ s|\.[\w-]+$||;
            $destination =~ s|/req\.|/req\.$backend_queue\.|;

            $expiration = $msg_headers->{'expiration'} || 60000;
            return unless $expiration =~ m|^\d+$|;

            # RabbitMQ message-id: T_sub-1@@session-yceVI9Lec0sAg2dyq2gGng@@101
            $session_id = $msg_headers->{'message-id'} || '';
            ($session_id) = ($session_id =~ m|\@\@session-([\w-]{22})\@\@|);
            return unless defined $session_id;

            # RabbitMQ reply-to: /reply-queue/amq.gen-B9LY-y22H8K9RLADnEh0Ww
            $reply_to = $msg_headers->{'reply-to'} || '';
            return unless $reply_to =~ m|^/topic/tmp\.[\w-]+$|; #TODO: not private
          # return unless $reply_to =~ m|^/reply-queue/amq\.gen-[\w-]+$|;

            #TODO: we could check that $body_ref is a valid JSON-RPC request

            #TODO: round robin
            my ($backend_bus) = values %{$self->{BACKEND}};

            $backend_bus->send(
                'destination'     => $destination,
                'x-session-id'    => $session_id,
                'reply-to'        => "/queue/res.$frontend_queue",
                'x-forward-reply' => "$reply_to\@$frontend_id",
              # 'content-type'    => $msg_headers->{'content-type'},
                'expiration'      => $expiration,
                'body'            => $body_ref,
            );

            $self->{_WORKER}->{jobs_count}++;
        },
    );
}

sub pull_backend_responses {
    my ($self, $backend_bus) = @_;

    # Get responses from backend and send them back to frontend

    my $frontend_queue = $self->{frontend_queue};
    my ($body_ref, $msg_headers, $destination, $frontend_bus);

    $backend_bus->subscribe(

        destination    => "/queue/res.$frontend_queue",
        ack            => 'auto', # means none
        on_receive_msg => sub {
            ($body_ref, $msg_headers) = @_;

            $destination = $msg_headers->{'x-forward-reply'};
            $destination =~ s/\@([\w-]+)$//;

            $frontend_bus = $self->{FRONTEND}->{$1} || return;

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
    my ($self, $backend_bus) = @_;

    # Get notifications from backend and broadcast them to frontend

    my $frontend_queue = $self->{frontend_queue};
    my ($body_ref, $msg_headers, $destination);

    $backend_bus->subscribe(

        destination    => "/queue/msg.$frontend_queue",
        ack            => 'auto', # means none
        on_receive_msg => sub {
            ($body_ref, $msg_headers) = @_;

            $destination = $msg_headers->{'x-forward-to'};

            if ($destination =~ m/\@([\w-]+)$/) {
                #TODO: Unicast
            }

            foreach my $frontend_bus (values %{$self->{FRONTEND}}) {

                $frontend_bus->send(
                    'destination'  => $destination,
                  # 'content-type' => $msg_headers->{'content-type'},
                    'body'         => $body_ref,
                );
            }

            $self->{_WORKER}->{notif_count}++;
        },
    );
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
