package Beekeeper::Worker;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Worker - Base class...

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

  package MyApp::Worker;
  
  use base 'Beekeeper::Worker';
  
  sub on_startup {
      my $self = shift;
      
      $self->accept_notifications(
          'myapp.msg' => 'got_message',
      );
      
      $self->accept_jobs(
          'myapp.sum' => 'do_sum',
      );
  }
  
  sub got_message {
      my ($self, $params) = @_;
      warn $params->{message};
  }
  
  sub do_sum {
      my ($self, $params) = @_;
      return $params->[0] + $params->[1];
  }

=head1 DESCRIPTION

Base class for creating services.


=head1 TODO

- Authorize request

- Stop working gracefully.

- Handle STOMP disconnections gracefully.

- Handle SIGTERM gracefully on VM shutdown.


=head1 METHODS

=cut


use Beekeeper::Client ':worker';
use Beekeeper::Logger ':log_levels';
use Beekeeper::JSONRPC;

use JSON::XS;
use Time::HiRes;
use Sys::Hostname;
use Carp;

#TODO: our @CARP_NOT = ('AnyEvent', 'Beekeeper::Bus::STOMP');

use constant COMPILE_ERROR_EXIT_CODE => 99;
use constant REPORT_STATUS_PERIOD    => 5;
use constant REQUEST_AUTHORIZED      => int(rand(90000000)+10000000);

use Exporter 'import';

our @EXPORT = qw( REQUEST_AUTHORIZED );

our @EXPORT_OK = qw(
    log_emergency
    log_alert
    log_critical
    log_error
    log_warn
    log_warning
    log_notice
    log_info
    log_debug
    log_trace
);

our %EXPORT_TAGS = ('log' => [ @EXPORT_OK, @EXPORT ]);

our $Logger = sub { warn(@_) }; # redefined later by __init_logger

sub log_emergency (@) { $Logger->( LOG_EMERG,  @_ ) }
sub log_alert     (@) { $Logger->( LOG_ALERT,  @_ ) }
sub log_critical  (@) { $Logger->( LOG_CRIT,   @_ ) }
sub log_error     (@) { $Logger->( LOG_ERROR,  @_ ) }
sub log_warn      (@) { $Logger->( LOG_WARN,   @_ ) }
sub log_warning   (@) { $Logger->( LOG_WARN,   @_ ) }
sub log_notice    (@) { $Logger->( LOG_NOTICE, @_ ) }
sub log_info      (@) { $Logger->( LOG_INFO,   @_ ) }
sub log_debug     (@) { $Logger->( LOG_DEBUG,  @_ ) }
sub log_trace     (@) { $Logger->( LOG_TRACE,  @_ ) }

our $JSON;


sub new {
    my ($class, %args) = @_;

    # Parameters passed by WorkerPool->spawn_worker
    
    my $self = {
        _WORKER => undef,
        _CLIENT => undef,
        _BUS    => undef,
        _LOGGER => undef,
    };

    bless $self, $class;

    $self->{_WORKER} = {
        parent_pid      => $args{'parent_pid'},
        foreground      => $args{'foreground'},   # --foreground option
        debug           => $args{'debug'},        # --debug option
        bus_config      => $args{'bus_config'},   # from bus.config.json
        pool_config     => $args{'pool_config'},  # from pool.config.json
        pool_id         => $args{'pool_id'},
        bus_id          => $args{'bus_id'},
        config          => $args{'config'},
        hostname        => hostname(),
        stop_cv         => undef,
        callbacks       => {},
        job_queue_high  => [],
        job_queue_low   => [],
        queued_tasks    => 0,
        last_report     => 0,
        jobs_count      => 0,
        notif_count     => 0,
        busy_time       => 0,
        busy_since      => 0,
    };

    $JSON = JSON::XS->new;
    $JSON->utf8;             # encode result as utf8
    $JSON->convert_blessed;  # use TO_JSON methods to serialize objects

    eval {

        # Init logger as soon as possible
        $self->__init_logger;

        # Connect to broker
        $self->__init_client;

        #HACK: pass to stomp_conn to logger
        $self->{_LOGGER}->{stomp_conn} = $self->{_BUS};

        $self->__init_worker;
    };

    if ($@) {
        log_error "Worker died while initialization: $@";
        log_error "$class could not be started";
        CORE::exit( COMPILE_ERROR_EXIT_CODE );
    }

    return $self;
}

sub __init_logger {
    my $self = shift;

    my $log_handler  = $self->log_handler;
    $self->{_LOGGER} = $log_handler;

    $Logger = sub {
        # ($level, @messages) = @_
        $log_handler->log(@_);
    };

    $SIG{__WARN__} = sub { $Logger->( LOG_WARN,  @_ ) };
}

sub __init_client {
    my $self = shift;

    my $client = Beekeeper::Client->new(
        bus_id  => $self->{_WORKER}->{bus_id},
        timeout => 0,  # retry forever
    );

    $self->{_CLIENT} = $client->{_CLIENT};
    $self->{_BUS}    = $client->{_BUS};

    $Beekeeper::Client::singleton = $self;
}

sub __init_worker {
    my $self = shift;

    $self->on_startup;

    if (defined $SIG{INT} && $SIG{INT} eq 'DEFAULT') {
        # Stop working when INT signal is received
        $SIG{INT} = sub { $self->stop_working };
    }

    #TODO: (0, 15) SIGTERM on VM shutdown not handled by childs

    $self->__report_status;

    $self->{_WORKER}->{report_status_timer} = AnyEvent->timer(
        after    => rand( REPORT_STATUS_PERIOD ), 
        interval => REPORT_STATUS_PERIOD,
        cb       => sub { $self->__report_status },
    );
}


sub on_startup {
    # Placeholder, intended to be overrided
    my $class = ref $_[0];
    warn "Worker class $class doesn't define on_startup() method";
}

sub on_shutdown {
    # Placeholder, can be overrided if necessary
}

sub authorize_request {
    # Placeholder, intended to be overrided
    my $class = ref $_[0];
    warn "Worker class $class doesn't define authorize_request() method";
    return undef; # do NOT authorize
}

=item accept_notifications ( $method => $callback, ... )

Make this worker start accepting specified JSON-RPC notifications from STOMP bus.

C<$method> is a string with the format "service_name.method_name". A default
or fallback handler can be specified using a wildcard as "service_name.*".

C<$callback> is a method name or a coderef that will be called when a notification
is received. When executed, the callback will receive two parameters C<$params> 
(which contains the notification data itself) and C<$req> which is a
Beekeeper::JSONRPC::Notification object (usually redundant).

Notifications are not expected to return a value.

Example:

  package MyWorker;
  use base 'Beekeeper::Worker';
  
  sub on_startup {
      my $self = shift;
      
      $self->accept_notifications(
          'foo.bar' => 'bar',       # call $self->bar for notifications 'foo.bar'
          'foo.baz' => $coderef,    # call $self->$coderef for notifications 'foo.baz'
          'foo.*'   => 'fallback',  # call $self->fallback for any other 'foo.*'
      );
  }  
  
  sub bar {
       my ($self, $params, $req) = @_
       
       # $self is a MyWorker object
       # $params is a ref to the notification data
       # $req is a Beekeeper::JSONRPC::Notification object
  }

=cut

sub accept_notifications {
    my ($self, %args) = @_;

    my $worker    = $self->{_WORKER};
    my $callbacks = $worker->{callbacks};

    foreach my $fq_meth (keys %args) {

        $fq_meth =~ m/^  ( [\w-]+ (?: \.[\w-]+ )* ) 
                      \. ( [\w-]+ | \* ) $/x or croak "Invalid notification method $fq_meth";

        my ($service, $method) = ($1, $2);
        my $local_bus = $self->{_BUS}->{bus_id};

        my $callback = $self->__get_cb_coderef($fq_meth, $args{$fq_meth});

        croak "Method $fq_meth declared twice" if exists $callbacks->{"msg.$fq_meth"};
        $callbacks->{"msg.$fq_meth"} = $callback;

        $self->{_BUS}->subscribe(
            destination    => "/topic/msg.$local_bus.$service.$method",
            ack            => 'auto', # means none
            on_receive_msg => sub {
                # ($body_ref, $msg_headers) = @_;

                # Enqueue notification
                push @{$worker->{job_queue_high}}, [ @_ ];

                unless ($worker->{queued_tasks}) {
                    $worker->{queued_tasks} = 1;
                    $worker->{busy_since} = Time::HiRes::time;
                    AnyEvent::postpone { $self->__drain_task_queue };
                }
            }
        );
    }
}

sub __get_cb_coderef {
    my ($self, $method, $callback) = @_;

    if (ref $callback eq 'CODE') {
        # Already a coderef
        return $callback;
    }
    elsif (!ref($callback) && $self->can($callback)) {
        # Return a reference to given method
        no strict 'refs';
        my $class = ref $self;
        return \&{"${class}::${callback}"};
    }
    else {
        croak "Invalid callback '$callback' for '$method'";
    }
}

=item accept_jobs ( $method => $callback, ... )

Make this worker start accepting specified JSON-RPC requests from STOMP bus.

C<$method> is a string with the format "service_name.method_name". A default
or fallback handler can be specified using a wildcard as "service_name.*".

C<$callback> is a method name or a coderef that will be called when a request
is received. When executed, the callback will receive two parameters C<$params> 
(which contains the notification data itself) and C<$req> which is a
Beekeeper::JSONRPC::Request object (usually redundant).

The value or data ref returned by the callback will be sent back to the caller
as response. If the callback dies the caller will receive an error response.

Example:

  package MyWorker;
  use base 'Beekeeper::Worker';
  
  sub on_startup {
      my $self = shift;
      
      $self->accept_jobs(
          'foo.inc' => 'inc',       # call $self->inc for requests to 'foo.inc'
          'foo.baz' => $coderef,    # call $self->$coderef for requests to 'foo.baz'
          'foo.*'   => 'fallback',  # call $self->fallback for any other 'foo.*'
      );
  }
  
  sub bar {
       my ($self, $params, $req) = @_
       
       # $self is a MyWorker object
       # $params is a ref to the parameters of the request
       # $req is a Beekeeper::JSONRPC::Request object
       
       return $params->{number} + 1;
  }

=cut

sub accept_jobs {
    my ($self, %args) = @_;

    my $worker = $self->{_WORKER};
    my $callbacks = $worker->{callbacks};
    my %subscribed_to;

    foreach my $fq_meth (keys %args) {

        $fq_meth =~ m/^  ( [\w-]+ (?: \.[\w-]+ )* ) 
                      \. ( [\w-]+ | \* ) $/x or croak "Invalid job method $fq_meth";

        my ($service, $method) = ($1, $2);
        my $local_bus = $self->{_BUS}->{bus_id};

        my $callback = $self->__get_cb_coderef($fq_meth, $args{$fq_meth});

        croak "Method $fq_meth declared twice" if exists $callbacks->{"req.$fq_meth"};
        $callbacks->{"req.$fq_meth"} = $callback;

        next if $subscribed_to{$service};
        $subscribed_to{$service} = 1;

        if (keys %subscribed_to > 1) {
            carp "Running multiple services within a single worker hurts load balancing";
        }

        $self->{_BUS}->subscribe(
            destination     => "/queue/req.$local_bus.$service",
            ack             => 'client', # manual ack
           'prefetch-count' => '1',
            on_receive_msg  => sub {
                # ($body_ref, $msg_headers) = @_;

                # Enqueue job
                push @{$worker->{job_queue_low}}, [ @_ ];

                unless ($worker->{queued_tasks}) {
                    $worker->{queued_tasks} = 1;
                    $worker->{busy_since} = Time::HiRes::time;
                    AnyEvent::postpone { $self->__drain_task_queue };
                }
            }
        );
    }
}

sub __drain_task_queue {
    my $self = shift;

    #TODO: Ensure that draining does not recurse

    my $worker = $self->{_WORKER};
    my $client = $self->{_CLIENT};
    my $task;

    # When jobs or notifications are received they are not executed immediately
    # because that could happen in the middle of the process of another request,
    # so these tasks get queued until the worker is ready to process the next one.
    #
    # Callbacks are executed here, exception handling is done here, responses are
    # sent back here. This is one of the most important methods of the framework.

    DRAIN: {

        while ($task = shift @{$worker->{job_queue_high}}) {

            ## Notification

            my ($body_ref, $msg_headers) = @$task;

            $worker->{notif_count}++;

            eval {

                my $request = decode_json($$body_ref);

                unless (ref $request eq 'HASH' && $request->{jsonrpc} eq '2.0') {
                    log_warn "Invalid JSON-RPC 2.0 request";
                    return;
                }

                bless $request, 'Beekeeper::JSONRPC::Notification';
                $request->{_headers} = $msg_headers;

                my $method = $request->{method};

                unless (defined $method && $method =~ m/^([\.\w-]+)\.([\w-]+)$/) {
                    log_warn "Invalid notification method";
                    return;
                }

                my $cb = $worker->{callbacks}->{"msg.$1.$2"} || 
                         $worker->{callbacks}->{"msg.$1.*"};

                unless (($self->authorize_request($request) || "") eq REQUEST_AUTHORIZED) {
                    log_warn "Notification $method was not authorized";
                    return;
                }

                unless ($cb) {
                    log_warn "No callback found for method $method";
                    return;
                }

                local $client->{auth_tokens} = $msg_headers->{'x-auth-tokens'};
                local $client->{session_id}  = $msg_headers->{'x-session'};

                $cb->($self, $request->{params}, $request);
            };

            if ($@) {
                # Got an exception while processing message
                log_error $@;
            }
        }

        if ($task = shift @{$worker->{job_queue_low}}) {

            ## RPC Call

            my ($body_ref, $msg_headers) = @$task;

            $worker->{jobs_count}++;
            my ($request, $request_id, $result, $response);

            $result = eval {

                $request = decode_json($$body_ref);

                unless (ref $request eq 'HASH' && $request->{jsonrpc} eq '2.0') {
                    log_warn "Invalid JSON-RPC 2.0 request";
                    return Beekeeper::JSONRPC::Error->invalid_request;
                }

                $request_id = $request->{id};
                my $method  = $request->{method};

                bless $request, 'Beekeeper::JSONRPC::Request';
                $request->{_headers} = $msg_headers;

                unless (defined $method && $method =~ m/^([\.\w-]+)\.([\w-]+)$/) {
                    log_warn "Invalid request method";
                    return Beekeeper::JSONRPC::Error->method_not_found;
                }

                my $cb = $worker->{callbacks}->{"req.$1.$2"} || 
                         $worker->{callbacks}->{"req.$1.*"};

                unless (($self->authorize_request($request) || "") eq REQUEST_AUTHORIZED) {
                    log_warn "Request $method was not authorized";
                    return Beekeeper::JSONRPC::Error->request_not_authorized
                        unless ($method =~ m/_sync.\w+.dump/); #TODO: fix shared hash
                }

                unless ($cb) {
                    log_warn "No callback found for method $method";
                    return Beekeeper::JSONRPC::Error->method_not_found;
                }

                local $client->{auth_tokens} = $msg_headers->{'x-auth-tokens'};
                local $client->{session_id}  = $msg_headers->{'x-session'};

                # Execute job
                $cb->($self, $request->{params}, $request);
            };

            if ($@) {
                # Got an exception while executing job
                log_error $@;
                $response = Beekeeper::JSONRPC::Error->server_error;
                $response = $@ if $@->isa('Beekeeper::JSONRPC::Error');
            }
            else {
                # Build a success response
                $response = {
                    jsonrpc => '2.0',
                    result  => $result,
                };
            }

            if ($request_id) {

                # Send response back to caller

                $response->{id} = $request_id;

                my $json = eval { $JSON->encode( $response ) };

                if ($@) {
                    # Probably response contains blessed references 
                    log_error "Couldn't serialize response as JSON: $@";
                    $response = Beekeeper::JSONRPC::Error->server_error;
                    $response->{id} = $request_id;
                    $json = $JSON->encode( $response );
                }

                $self->{_BUS}->ack(
                    'id'           => $msg_headers->{'message-id'},
                    'subscription' => $msg_headers->{'subscription'},  # not needed in STOMP 1.2
                    'buffer_id'    => "txn-$request_id",
                );

                $self->{_BUS}->send(
                    'destination'     => $msg_headers->{'reply-to'},
                    'x-forward-reply' => $msg_headers->{'x-forward-reply'},
                    'buffer_id'       => "txn-$request_id",
                    'body'            => \$json,
                );

                $self->{_BUS}->flush_buffer( 'buffer_id' => "txn-$request_id", );
            }
            else {

                # Background jobs doesn't expect responses

                $self->{_BUS}->ack(
                    'id'           => $msg_headers->{'message-id'},
                    'subscription' => $msg_headers->{'subscription'},
                );
            }
        }

        redo DRAIN if (@{$worker->{job_queue_high}} || @{$worker->{job_queue_low}})
    }

    # tack
    $worker->{busy_time} += Time::HiRes::time - $worker->{busy_since};
    $worker->{busy_since} = 0;

    $worker->{queued_tasks} = 0;
}

=item stop_accepting_notifications ( $method, ... )

Make this worker stop accepting specified JSON-RPC notifications from STOMP bus.

C<$method> must be one of the strings used previously in C<accept_notifications>.

=cut

sub stop_accepting_notifications {
    my ($self, @methods) = @_;

    croak "No method specified" unless @methods;

    foreach my $fq_meth (@methods) {

        $fq_meth =~ m/^  ( [\w-]+ (?: \.[\w-]+ )* ) 
                      \. ( [\w-]+ | \* ) $/x or croak "Invalid method $fq_meth";

        my ($service, $method) = ($1, $2);
        my $local_bus = $self->{_BUS}->{bus_id};

        unless (defined $self->{_WORKER}->{callbacks}->{"msg.$fq_meth"}) {
            carp "Not previously accepting notifications $fq_meth";
            next;
        }

        $self->{_BUS}->unsubscribe(
            destination => "/topic/msg.$local_bus.$service.$method",
            on_success  => sub {
                #BUG: Some notifications may be still queued, which will cause warnings
                delete $self->{_WORKER}->{callbacks}->{"msg.$fq_meth"};
            }
        );
    }
}

=item stop_accepting_jobs ( $method, ... )

Make this worker stop accepting specified JSON-RPC requests from STOMP bus.

C<$method> must be one of the strings used previously in C<accept_jobs>.

=cut

sub stop_accepting_jobs {
    my ($self, @methods) = @_;

    croak "No method specified" unless @methods;

    foreach my $fq_meth (@methods) {

        $fq_meth =~ m/^  ( [\w-]+ (?: \.[\w-]+ )* ) 
                      \. ( [\w-]+ | \* ) $/x or croak "Invalid method $fq_meth";

        my ($service, $method) = ($1, $2);
        my $local_bus = $self->{_BUS}->{bus_id};

        unless (defined $self->{_WORKER}->{callbacks}->{"req.$fq_meth"}) {
            carp "Not previously accepting jobs $fq_meth";
            next;
        }

        $self->{_BUS}->unsubscribe(
            destination => "/queue/req.$local_bus.$service",
            on_success  => sub {
                #BUG: A single job may still be queued, NACK it
                delete $self->{_WORKER}->{callbacks}->{"req.$fq_meth"};
            }
        );
    }
}

sub __work_forever {
    my $self = shift;

    # Called by WorkerPool->spawn_worker

    eval {

        my $worker = $self->{_WORKER};

        $worker->{stop_cv} = AnyEvent->condvar;

        # Blocks here until stop_working is called
        $worker->{stop_cv}->recv;

        $self->on_shutdown;

        $self->__report_exit;
    };

    if ($@) {
        log_error "Worker died: $@";
        CORE::exit(255);
    }

    $self->{_BUS}->disconnect( blocking => 1 );
}

=item stop_working 

=cut

sub stop_working {
    my $self = shift;

    $self->{_WORKER}->{stop_cv}->send;
}


sub __report_status {
    my $self = shift;

    my $worker = $self->{_WORKER};

    my $now = Time::HiRes::time;
    my $period = $now - ($worker->{last_report} || ($now - 1));

    $worker->{last_report} = $now;

    # Average jobs per second
    my $jps = sprintf("%.2f", $worker->{jobs_count} / $period);
    $worker->{jobs_count} = 0;

    # Average notifications per second
    my $nps = sprintf("%.2f", $worker->{notif_count} / $period);
    $worker->{notif_count} = 0;

    # Average load
    my $load = sprintf("%.2f", $worker->{busy_time} / $period * 100);
    $worker->{busy_time} = 0;

    #TODO: errors count

    # Queues
    my %queues;
    foreach my $queue (keys %{$worker->{callbacks}}) {
        next unless $queue =~ m/^req\.(?!_sync)(.*)\./;
        $queues{$1} = 1;
    }

    #
    $self->do_background_job(
        method => '_bkpr.supervisor.worker_status',
        _auth_ => '0,BKPR_SYSTEM',
        params => {
            class => ref($self),
            host  => $worker->{hostname},
            pool  => $worker->{pool_id},
            pid   => $$,
            jps   => $jps,
            nps   => $nps,
            load  => $load,
            queue => [ keys %queues ],
        },
    );
}

sub __report_exit {
    my $self = shift;

    my $worker = $self->{_WORKER};

    $self->do_background_job(
        method => '_bkpr.supervisor.worker_exit',
        _auth_ => '0,BKPR_SYSTEM',
        params => {
            class => ref($self),
            host  => $worker->{hostname},
            pool  => $worker->{pool_id},
            pid   => $$,
        },
    );
}

=item log_handler 

=cut

sub log_handler {
    my $self = shift;

    Beekeeper::Logger->new(
        worker_class => ref $self,
        stomp_conn   => $self->{_BUS},
        foreground   => $self->{_WORKER}->{foreground},
        log_file     => $self->{_WORKER}->{config}->{log_file},
        host         => $self->{_WORKER}->{hostname},
        pool         => $self->{_WORKER}->{pool_id},
        @_
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
