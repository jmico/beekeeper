package Beekeeper::Client;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME
 
Beekeeper::Client - ...
 
=head1 VERSION
 
Version 0.01

=head1 SYNOPSIS

  my $client = Beekeeper::Client->new;
  
  $client->send_notification(
      method => "my.service.foo",
      params => { msg => $message },
  );
  
  $client->do_background_job(
      method => "my.service.bar",
      params => { %args },
  );
  
  my $result = $client->do_job(
      method => "my.service.baz",
      params => { %args },
  );

=head1 DESCRIPTION

=head1 TODO

- Handle STOMP disconnections gracefully

=cut

use Beekeeper::Bus::STOMP;
use Beekeeper::JSONRPC;
use Beekeeper::Config;

use JSON::XS;
use Sys::Hostname;
use Time::HiRes;
use Carp;

use constant TXN_CLIENT_SIDE => 1;
use constant TXN_SERVER_SIDE => 2;
use constant REQ_TIMEOUT     => 20;  #TODO: 60

use Exporter 'import';

our @EXPORT_OK = qw(
    send_notification
    do_job
    do_async_job
    do_background_job
    wait_all_jobs
    set_credentials
    __do_rpc_request
    __create_reply_queue
);

our %EXPORT_TAGS = ('worker' => \@EXPORT_OK );

our $singleton;


sub new {
    my ($class, %args) = @_;

    my $self = {
        _CLIENT => undef,
        _BUS    => undef,
    };

    $self->{_CLIENT} = {
        callbacks      => {},
        reply_queue    => undef,
        correlation_id => undef,
        in_progress    => undef,
        transaction    => undef,
        transaction_id => undef,
        auth_tokens    => undef,
        session_id     => undef,
        async_cv       => undef,
    };

    unless (exists $args{'host'} && exists $args{'user'} && exists $args{'pass'}) {

        my $bus_id = $args{'bus_id'};

        if (defined $bus_id) {
            # Get broker connection parameters from config file
            my $config = Beekeeper::Config->get_bus_config( %args );
            croak "Bus '$bus_id' is not defined into config file bus.config.json" unless $config;
            %args = ( %$config, %args );
        }
        else {
            # Use connection parameters for default bus (if any)
            my $config = Beekeeper::Config->get_bus_config( bus_id => '*', %args );
            my ($default) = grep { $config->{$_}->{default} } keys %$config;
            croak "No default bus defined into config file bus.config.json" unless $default;
            $bus_id = $config->{$default}->{'bus-id'};
            %args = ( %{$config->{$default}}, %args, bus_id => $bus_id );
        }
    }

    $self->{_BUS} = Beekeeper::Bus::STOMP->new( %args );

    # Connect to STOMP broker
    $self->{_BUS}->connect( blocking => 1 );

    bless $self, $class;
    return $self;
}

sub instance {
    my $class = shift;

    if ($singleton) {
        # Return existing singleton
        return $singleton;
    }

    # Create a new instance
    my $self = $class->new( @_ );

    # Keep a global reference to $self
    $singleton = $self;

    return $self;
}

=pod

=head1 METHODS

                  result   
notification        no     all workers
background job      no     single worker
sync/async job      yes    single worker

=over 4

=item send_notification( method => $method, params => $params )

Broadcast a JSON-RPC notification to the STOMP bus. All workers listening for
C<$method> (a string with the format "service_name.method_name") will receive it.

C<$params> is an arbitrary value or data structure sent with the notification.

=cut

sub send_notification {
    my ($self, %args) = @_;

    my $fq_meth = $args{'method'} or croak "Method was not specified";

    $fq_meth =~ m/^     ( [\w-]+ (?:\.[\w-]+)* )
                     \. ( [\w-]+ ) 
                 (?: \@ ( [\w-]+ ) (\.[\w-]+)* )? $/x or croak "Invalid method $fq_meth";

    my ($service, $method, $bus, $addr) = ($1, $2, $3, $4);
    my $local_bus = $self->{_BUS}->{bus_id};

    my $json = encode_json({
        jsonrpc => '2.0',
        method  => "$service.$method",
        params  => $args{'params'},
    });

    my %send_args;

    if (defined $bus) {
        $send_args{'destination'}  = "/queue/msg.$bus";
        $send_args{'x-forward-to'} = "/topic/msg.$bus.$service.$method";
        $send_args{'x-forward-to'} .= "\@$addr" if (defined $addr && $addr =~ s/^\.//);
    }
    else {
        $send_args{'destination'} = "/topic/msg.$local_bus.$service.$method";
    }

    if (exists $args{'_auth_'}) {
        $send_args{'x-auth-tokens'} = $args{'_auth_'};
    }
    else {
        $send_args{'x-auth-tokens'} = $self->{_CLIENT}->{auth_tokens};
        $send_args{'x-session'}     = $self->{_CLIENT}->{session_id};
    }

    if ($self->{transaction}) {
        my $hdr = $self->{transaction} == TXN_CLIENT_SIDE ? 'buffer_id' : 'transaction';
        $send_args{$hdr} = $self->{transaction_id};
    }

    $self->{_BUS}->send( body => \$json, %send_args );
}


sub accept_notifications {
    my ($self, %args) = @_;

    my $callbacks = $self->{_CLIENT}->{callbacks};

    foreach my $fq_meth (keys %args) {

        $fq_meth =~ m/^  ( [\w-]+ (?: \.[\w-]+ )* ) 
                      \. ( [\w-]+ | \* ) $/x or croak "Invalid notification method $fq_meth";

        my ($service, $method) = ($1, $2);
        my $local_bus = $self->{_BUS}->{bus_id};

        my $callback = $args{$fq_meth};

        unless (ref $callback eq 'CODE') {
            croak "Invalid callback for '$method'";
        }

        croak "Already accepting notifications $fq_meth" if exists $callbacks->{"msg.$fq_meth"};
        $callbacks->{"msg.$fq_meth"} = $callback;

        #TODO: Allow to accept private notifications without subscribing

        $self->{_BUS}->subscribe(
            destination    => "/topic/msg.$local_bus.$service.$method",
            ack            => 'auto', # means none
            on_receive_msg => sub {
                my ($body_ref, $msg_headers) = @_;

                my $request = eval { decode_json($$body_ref) };

                unless (ref $request eq 'HASH' && $request->{jsonrpc} eq '2.0') {
                    warn "Received invalid JSON-RPC 2.0 notification";
                    return;
                }

                bless $request, 'Beekeeper::JSONRPC::Notification';
                $request->{_headers} = $msg_headers;

                my $method = $request->{method};

                unless (defined $method && $method =~ m/^([\.\w-]+)\.([\w-]+)$/) {
                    warn "Received notification with invalid method $method";
                    return;
                }

                my $cb = $callbacks->{"msg.$1.$2"} || 
                         $callbacks->{"msg.$1.*"};

                unless ($cb) {
                    warn "No callback found for received notification $method";
                    return;
                }

                $cb->($request->{params}, $request);
            }
        );
    }
}

sub stop_accepting_notifications {
    my ($self, @methods) = @_;

    croak "No method specified" unless @methods;

    foreach my $fq_meth (@methods) {

        $fq_meth =~ m/^  ( [\w-]+ (?: \.[\w-]+ )* ) 
                      \. ( [\w-]+ | \* ) $/x or croak "Invalid method $fq_meth";

        my ($service, $method) = ($1, $2);
        my $local_bus = $self->{_BUS}->{bus_id};

        unless (defined $self->{_CLIENT}->{callbacks}->{"msg.$fq_meth"}) {
            carp "Not previously accepting notifications $fq_meth";
            next;
        }

        $self->{_BUS}->unsubscribe(
            destination => "/topic/msg.$local_bus.$service.$method",
            on_success  => sub {
                #BUG: Some notifications may be still received, which will cause warnings
                delete $self->{_CLIENT}->{callbacks}->{"msg.$fq_meth"};
            }
        );
    }
}

=pod

=item do_job

=over4

=item method

=item params

=item timeout

=item raise_error

=back

=cut

our $WAITING;

sub do_job {
    my $self = shift;

    my $req = $self->__do_rpc_request( @_, req_type => 'SYNCHRONOUS' );

    #HACK: Force AnyEvent to allow one level of recursive condvar blocking
    $WAITING && croak "Recursive condvar blocking wait attempted";
    local $WAITING = 1;
    local $AnyEvent::CondVar::Base::WAITING = 0;

    # Block until a response is received or request timed out
    $req->{_waiting_response}->recv;

    my $resp = $req->{_response};

    if (!exists $resp->{result} && $req->{_raise_error}) {
        my $errmsg = $resp->message . ( $resp->data ? ': ' . $resp->data : '' );
        croak "Call to '$req->{method}' failed: $errmsg";
    }

    #TODO: On_sucess, on_timeout, on_error ?
    return $resp;
}

sub do_async_job {
    my $self = shift;

    my $req = $self->__do_rpc_request( @_, req_type => 'ASYNCHRONOUS' );
    
    return $req;
}

sub do_background_job {
    my $self = shift;

    # Send job to a worker, but do not wait for result
    $self->__do_rpc_request( @_, req_type => 'BACKGROUND' );

    return;
}

sub __do_rpc_request {
    my ($self, %args) = @_;
    my $client = $self->{_CLIENT};

    my $fq_meth = $args{'method'} or croak "Method was not specified";

    $fq_meth =~ m/^     ( [\w-]+ (?:\.[\w-]+)* )
                     \. ( [\w-]+ ) 
                 (?: \@ ( [\w-]+ ) (\.[\w-]+)* )? $/x or croak "Invalid method $fq_meth";

    my ($service, $method, $bus, $addr) = ($1, $2, $3, $4);
    my $local_bus = $self->{_BUS}->{bus_id};

    my %send_args;

    if (defined $bus) {
        $send_args{'destination'}  = "/queue/req.$bus";
        $send_args{'x-forward-to'} = "/queue/req.$bus.$service";
        $send_args{'x-forward-to'} .= "\@$addr" if (defined $addr && $addr =~ s/^\.//);
    }
    else {
        $send_args{'destination'} = "/queue/req.$local_bus.$service";
    }

    if (exists $args{'_auth_'}) {
        $send_args{'x-auth-tokens'} = $args{'_auth_'};
    }
    else {
        $send_args{'x-auth-tokens'} = $client->{auth_tokens};
        $send_args{'x-session'}     = $client->{session_id};
    }

    my $timeout = $args{'timeout'} || REQ_TIMEOUT;
    $send_args{'expiration'} = int( $timeout * 1000 );


    my $BACKGROUND  = $args{req_type} eq 'BACKGROUND';
    my $SYNCHRONOUS = $args{req_type} eq 'SYNCHRONOUS';
    my $raise_error = $args{'raise_error'};
    my $req_id;

    # JSON-RPC call
    my $req = {
        jsonrpc => '2.0',
        method  => "$service.$method",
        params  => $args{'params'},
    };

    unless ($BACKGROUND) {

        # Reuse or create a private reply queue which will receive the response
        my $reply_queue = $client->{reply_queue} || $self->__create_reply_queue;
        $send_args{'reply-to'} = $reply_queue;

        # Assign an unique request id (unique only for this client)
        $req_id = int(rand(90000000)+10000000) . '-' . $client->{correlation_id}++;
        $req->{'id'} = $req_id;
    }

    my $json = encode_json($req);

    if ($BACKGROUND && $self->{transaction}) {
        my $hdr = $self->{transaction} == TXN_CLIENT_SIDE ? 'buffer_id' : 'transaction';
        $send_args{$hdr} = $self->{transaction_id};
    }

    # Send request
    $self->{_BUS}->send( body => \$json, %send_args );

    if ($BACKGROUND) {
         # Nothing else to do
         return;
    }
    elsif ($SYNCHRONOUS) {

        $req->{_raise_error} = (defined $raise_error) ? $raise_error : 1;
        #TODO:
        # $req->{_on_error_cb} = sub {
        #     my $resp = shift;
        #     my $errmsg = $resp->message . ( $resp->data ? ': ' . $resp->data : '' );
        #     croak "Call to '$req->{method}' failed: $errmsg";
        # }

        # Callback will be...
        $req->{_waiting_response} = AnyEvent->condvar;
        $req->{_waiting_response}->begin;
    }
    else {

        # Use shared cv for all requests
        if (!$client->{async_cv} || $client->{async_cv}->ready) {
            $client->{async_cv} = AnyEvent->condvar;
        }

        $req->{_waiting_response} = $client->{async_cv};
        $req->{_waiting_response}->begin;
    }

    $client->{in_progress}->{$req_id} = $req;

    # Request timeout timer
    $req->{_timeout} = AnyEvent->timer( after => $timeout, cb => sub {
        my $req = delete $client->{in_progress}->{$req_id};
        $req->{_response} = Beekeeper::JSONRPC::Error->request_timeout;
        $req->{_on_error_cb}->($req->{_response}) if $req->{_on_error_cb};
        $req->{_waiting_response}->end;
    });

    #TODO: raise error should be true unless error cb
    $req->{_on_success_cb} = $args{'on_success'};
    $req->{_on_error_cb}   = $args{'on_error'};

    bless $req, 'Beekeeper::JSONRPC::Request';
    return $req;
}

sub __create_reply_queue {
    my $self = shift;
    my $client = $self->{_CLIENT};

    # Create an exclusive auto-delete queue for receiving RPC responses.

    my $reply_queue = '/temp-queue/reply-' . int(rand(90000000)+10000000);
    $client->{reply_queue} = $reply_queue;

    $self->{_BUS}->subscribe(
        destination    => $reply_queue,
        ack            => 'auto',
        on_receive_msg => sub {
            my ($body_ref, $msg_headers) = @_;

            my $resp = eval { decode_json($$body_ref) };

            unless (ref $resp eq 'HASH' && $resp->{jsonrpc} eq '2.0') {
                warn "Received invalid JSON-RPC 2.0 message";
                return;
            }

            if (exists $resp->{'id'}) {

                # Response of an RPC request

                my $req_id = $resp->{'id'};
                my $req = delete $client->{in_progress}->{$req_id};

                # Ignore unexpected responses
                return unless $req;

                # Cancel request timeout
                delete $req->{_timeout};

                if (exists $resp->{'result'}) {
                    # Success response
                    $req->{_response} = bless $resp, 'Beekeeper::JSONRPC::Response';
                    $req->{_on_success_cb}->($resp) if $req->{_on_success_cb};
                }
                else {
                    # Error response
                    $req->{_response} = bless $resp, 'Beekeeper::JSONRPC::Error';
                    $req->{_on_error_cb}->($resp) if $req->{_on_error_cb};
                }
        
                $req->{_waiting_response}->end;
            }
            else {

                # Unicasted notification

                bless $resp, 'Beekeeper::JSONRPC::Notification';
                $resp->{_headers} = $msg_headers;

                my $method = $resp->{method};

                unless (defined $method && $method =~ m/^([\.\w-]+)\.([\w-]+)$/) {
                    warn "Received notification with invalid method $method";
                    return;
                }

                my $cb = $client->{callbacks}->{"msg.$1.$2"} || 
                         $client->{callbacks}->{"msg.$1.*"};

                unless ($cb) {
                    warn "No callback found for received notification $method";
                    return;
                }

                $cb->($resp->{params}, $resp);
            }

        },
    );

    return $reply_queue;
}


sub wait_all_jobs {
    my $self = shift;

    #DOC: no croak if any job failed

    # wait for all pending jobs
    my $cv = delete $self->{_CLIENT}->{async_cv};

    #HACK: Force AnyEvent to allow one level of recursive condvar blocking
    $WAITING && croak "Recursive condvar blocking wait attempted";
    local $WAITING = 1;
    local $AnyEvent::CondVar::Base::WAITING = 0;

    $cv->recv;
}


sub set_credentials {
    my ($self, %args) = @_;

    my $uuid   = $args{'uuid'}   || 0;
    my $tokens = $args{'tokens'} || [];

    croak "Invalid uuid $uuid" unless ($uuid =~ m/^[\w-]+$/);

    foreach my $token (@$tokens) {
        croak "Invalid token $token" unless ($token =~ m/^\w+$/);
    }

    $self->{_CLIENT}->{auth_tokens} = join(',', $uuid, @$tokens);
}

=pod

=item begin_transaction

=cut

sub ___begin_transaction {
    my ($self, %args) = @_;

    croak "Already in a transaction" if $self->{transaction};

    $self->{transaction_id}++;

    if ($args{'client_side'}) {
        # Client side
        $self->{transaction} = TXN_CLIENT_SIDE;

    }
    else {
        # Server side
        $self->{transaction} = TXN_SERVER_SIDE;
        $self->{_BUS}->begin( transaction => $self->{transaction_id} );
    }
}

sub ___commit_transaction {
    my $self = shift;

    croak "No transaction was previously started" unless $self->{transaction};

    if ($self->{transaction} == TXN_CLIENT_SIDE) {
        # Client side
        $self->{_BUS}->flush_buffer( buffer_id => $self->{transaction_id} );
    }
    else {
        # Server side
        $self->{_BUS}->commit( transaction => $self->{transaction_id} );
    }

    $self->{transaction} = undef;
}

sub ___abort_transaction {
    my $self = shift;

    croak "No transaction was previously started" unless $self->{transaction};

    if ($self->{transaction} == TXN_CLIENT_SIDE) {
        # Client side
        $self->{_BUS}->discard_buffer( buffer_id => $self->{transaction_id} );
    }
    else {
        # Server side
        $self->{_BUS}->abort( transaction => $self->{transaction_id} );
    }

    $self->{transaction} = undef;
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
