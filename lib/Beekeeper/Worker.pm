package Beekeeper::Worker;

use strict;
use warnings;

our $VERSION = '0.03';

use Beekeeper::Client ':worker';
use Beekeeper::Logger ':log_levels';
use Beekeeper::JSONRPC;

use JSON::XS;
use Time::HiRes;
use Sys::Hostname;
use Digest::SHA 'sha256_hex';
use Scalar::Util 'blessed';
use Carp;

#TODO: our @CARP_NOT = ('AnyEvent', 'Beekeeper::MQTT');

use constant COMPILE_ERROR_EXIT_CODE => 99;
use constant REPORT_STATUS_PERIOD    => 5;
use constant UNSUBSCRIBE_LINGER      => 2;
use constant BKPR_REQUEST_AUTHORIZED => int(rand(90000000)+10000000);

use Exporter 'import';

our @EXPORT = qw( BKPR_REQUEST_AUTHORIZED );

our @EXPORT_OK = qw(
    log_fatal
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
our $LogLevel = LOG_WARN;

sub log_fatal    (@) { $LogLevel >= LOG_FATAL  && $Logger->( LOG_FATAL,  @_ ) }
sub log_alert    (@) { $LogLevel >= LOG_ALERT  && $Logger->( LOG_ALERT,  @_ ) }
sub log_critical (@) { $LogLevel >= LOG_CRIT   && $Logger->( LOG_CRIT,   @_ ) }
sub log_error    (@) { $LogLevel >= LOG_ERROR  && $Logger->( LOG_ERROR,  @_ ) }
sub log_warn     (@) { $LogLevel >= LOG_WARN   && $Logger->( LOG_WARN,   @_ ) }
sub log_warning  (@) { $LogLevel >= LOG_WARN   && $Logger->( LOG_WARN,   @_ ) }
sub log_notice   (@) { $LogLevel >= LOG_NOTICE && $Logger->( LOG_NOTICE, @_ ) }
sub log_info     (@) { $LogLevel >= LOG_INFO   && $Logger->( LOG_INFO,   @_ ) }
sub log_debug    (@) { $LogLevel >= LOG_DEBUG  && $Logger->( LOG_DEBUG,  @_ ) }
sub log_trace    (@) { $LogLevel >= LOG_TRACE  && $Logger->( LOG_TRACE,  @_ ) }

my %AUTH_TOKENS;
my $JSON;


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
        bus_config      => $args{'bus_config'},   # content of bus.config.json
        pool_config     => $args{'pool_config'},  # content of pool.config.json
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
    $JSON->allow_blessed;    # encode blessed references as null
    $JSON->convert_blessed;  # use TO_JSON methods to serialize objects

    if (defined $SIG{TERM} && $SIG{TERM} eq 'DEFAULT') {
        # Stop working gracefully when TERM signal is received
        $SIG{TERM} = sub { $self->stop_working };
    }

    if (defined $SIG{INT} && $SIG{INT} eq 'DEFAULT' && $args{'foreground'}) {
        # In foreground mode also stop working gracefully when INT signal is received
        $SIG{INT} = sub { $self->stop_working };
    }

    eval {

        # Init logger as soon as possible
        $self->__init_logger;

        # Connect to broker
        $self->__init_client;

        # Pass broker connection to logger
        $self->{_LOGGER}->{_BUS} = $self->{_BUS} if (exists $self->{_LOGGER}->{_BUS});

        $self->__init_auth_tokens;

        $self->__init_worker;
    };

    if ($@) {
        log_error "Worker died while initialization: $@";
        log_error "$class could not be started";
        CORE::exit( COMPILE_ERROR_EXIT_CODE );
    }

    return $self;
}

sub __init_auth_tokens {
    my ($self) = @_;

    my $secret = 'salt'; #TODO: read from config file

    $AUTH_TOKENS{'BKPR_SYSTEM'} = sha256_hex('BKPR_SYSTEM'. $secret);
    $AUTH_TOKENS{'BKPR_ADMIN'}  = sha256_hex('BKPR_ADMIN' . $secret);
    $AUTH_TOKENS{'BKPR_ROUTER'} = sha256_hex('BKPR_ROUTER'. $secret);
}

sub __has_authorization_token {
    my ($self, $auth_level) = @_;

    my $auth_data = $self->{_CLIENT}->{auth_data};

    return 0 unless $auth_data && $auth_level;
    return 0 unless exists $AUTH_TOKENS{$auth_level};
    return 0 unless $AUTH_TOKENS{$auth_level} eq $auth_data;

    return 1;
}

sub __init_logger {
    my $self = shift;

    # Honor --debug command line option and 'debug' config option from pool.config.json
    $LogLevel = LOG_DEBUG if $self->{_WORKER}->{debug} || $self->{_WORKER}->{config}->{debug};

    my $log_handler  = $self->log_handler;
    $self->{_LOGGER} = $log_handler;

    $Logger = sub {
        # ($level, @messages) = @_
        $log_handler->log(@_);
    };

    $SIG{__WARN__} = sub { $Logger->( LOG_WARN,  @_ ) };
}

sub log_handler {
    my $self = shift;

    Beekeeper::Logger->new(
        worker_class => ref $self,
        foreground   => $self->{_WORKER}->{foreground},
        log_file     => $self->{_WORKER}->{config}->{log_file},
        host         => $self->{_WORKER}->{hostname},
        pool         => $self->{_WORKER}->{pool_id},
        _BUS         => $self->{_BUS},
        @_
    );
}

sub __init_client {
    my $self = shift;

    my $bus_id = $self->{_WORKER}->{bus_id};

    my $client = Beekeeper::Client->new(
        bus_id   => $bus_id,
        timeout  => 0,  # retry forever
        on_error => sub { 
            my $errmsg = $_[0] || ""; $errmsg =~ s/\s+/ /sg;
            log_fatal "Connection to $bus_id failed: $errmsg";
            $self->stop_working;
        },
    );

    $self->{_CLIENT} = $client->{_CLIENT};
    $self->{_BUS}    = $client->{_BUS};

    $Beekeeper::Client::singleton = $self;
}

sub __init_worker {
    my $self = shift;

    $self->on_startup;

    $self->__report_status;

    AnyEvent->now_update;

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
    # Placeholder, can be overrided
}

sub authorize_request {
    # Placeholder, must to be overrided
    my $class = ref $_[0];
    warn "Worker class $class doesn't define authorize_request() method";
    return undef; # do NOT authorize
}


sub accept_notifications {
    my ($self, %args) = @_;

    my $worker    = $self->{_WORKER};
    my $callbacks = $worker->{callbacks};

    foreach my $fq_meth (keys %args) {

        $fq_meth =~ m/^  ( [\w-]+ (?: \.[\w-]+ )* ) 
                      \. ( [\w-]+ | \* ) $/x or croak "Invalid notification method $fq_meth";

        my ($service, $method) = ($1, $2);

        my $callback = $self->__get_cb_coderef($fq_meth, $args{$fq_meth});

        #TODO: croak does not report correct caller
        croak "Already accepting notifications $fq_meth" if exists $callbacks->{"msg.$fq_meth"};
        $callbacks->{"msg.$fq_meth"} = $callback;

        my $local_bus = $self->{_BUS}->{cluster};

        my $topic = "msg/$local_bus/$service/$method";
        $topic =~ tr|.*|/#|;

        $self->{_BUS}->subscribe(
            topic      => $topic,
            on_publish => sub {
                # ($payload_ref, $properties) = @_;

                # Enqueue notification
                push @{$worker->{job_queue_high}}, [ @_ ];

                unless ($worker->{queued_tasks}) {
                    $worker->{queued_tasks} = 1;
                    $worker->{busy_since} = Time::HiRes::time;
                    AnyEvent::postpone { $self->__drain_task_queue };
                }
            },
            on_suback => sub {
                my ($success, $prop) = @_;
                croak "Could not subscribe to $topic" unless $success;
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


sub accept_jobs {
    my ($self, %args) = @_;

    my $worker = $self->{_WORKER};
    my $callbacks = $worker->{callbacks};
    my %subscribed_to;

    foreach my $fq_meth (keys %args) {

        $fq_meth =~ m/^  ( [\w-]+ (?: \.[\w-]+ )* ) 
                      \. ( [\w-]+ | \* ) $/x or croak "Invalid job method $fq_meth";

        my ($service, $method) = ($1, $2);

        my $callback = $self->__get_cb_coderef($fq_meth, $args{$fq_meth});

        #TODO: croak does not report correct caller
        croak "Already accepting jobs $fq_meth" if exists $callbacks->{"req.$fq_meth"};
        $callbacks->{"req.$fq_meth"} = $callback;

        next if $subscribed_to{$service};
        $subscribed_to{$service} = 1;

        if (keys %subscribed_to > 1) {
            carp "Running multiple services within a single worker hurts load balancing (don't do that)";
        }

        my $local_bus = $self->{_BUS}->{cluster};

        my $queue = "\$share/BKPR/req/$local_bus/$service";
        $queue =~ tr|.*|/#|;

        $self->{_BUS}->subscribe(
            topic       => $queue,
            maximum_qos => 1,
            on_publish  => sub {
                # ($body_ref, $msg_headers) = @_;

                # Enqueue job
                push @{$worker->{job_queue_low}}, [ @_ ];

                unless ($worker->{queued_tasks}) {
                    $worker->{queued_tasks} = 1;
                    $worker->{busy_since} = Time::HiRes::time;
                    AnyEvent::postpone { $self->__drain_task_queue };
                }
            },
            on_suback => sub {
                my ($success, $prop) = @_;
                croak "Could not subscribe to $queue" unless $success;
            }
        );
    }
}

my $_TASK_QUEUE_DEPTH = 0;

sub __drain_task_queue {
    my $self = shift;

    # Ensure that draining does not recurse
    die "Task queue processing is recursing" if ($_TASK_QUEUE_DEPTH);
    $_TASK_QUEUE_DEPTH++;

    my $worker = $self->{_WORKER};
    my $client = $self->{_CLIENT};
    my $task;

    # When jobs or notifications are received they are not executed immediately
    # because that could happen in the middle of the process of another request,
    # so these tasks get queued until the worker is ready to process the next one.
    #
    # Callbacks are executed here, exception handling is done here, responses are
    # sent back here. This is one of the most important methods of the framework.
    #
    # Notifications have higher priority and are processed first.

    DRAIN: {

        while ($task = shift @{$worker->{job_queue_high}}) {

            ## Notification

            my ($body_ref, $msg_headers) = @$task;

            $worker->{notif_count}++;

            eval {

                my $request = decode_json($$body_ref);

                unless (ref $request eq 'HASH' && $request->{jsonrpc} eq '2.0') {
                    log_warn "Received invalid JSON-RPC 2.0 notification";
                    return;
                }

                bless $request, 'Beekeeper::JSONRPC::Notification';
                $request->{_mqtt_prop} = $msg_headers;

                my $method = $request->{method};

                unless (defined $method && $method =~ m/^([\.\w-]+)\.([\w-]+)$/) {
                    log_warn "Received notification with invalid method $method";
                    return;
                }

                my $cb = $worker->{callbacks}->{"msg.$1.$2"} || 
                         $worker->{callbacks}->{"msg.$1.*"};

                local $client->{caller_id}   = $msg_headers->{'clid'};
                local $client->{caller_addr} = $msg_headers->{'addr'};
                local $client->{auth_data}   = $msg_headers->{'auth'};

                unless (($self->authorize_request($request) || "") eq BKPR_REQUEST_AUTHORIZED) {
                    log_warn "Notification $method was not authorized";
                    return;
                }

                unless ($cb) {
                    log_warn "No callback found for received notification $method";
                    return;
                }

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
                    log_warn "Received invalid JSON-RPC 2.0 request";
                    die Beekeeper::JSONRPC::Error->invalid_request;
                }

                $request_id = $request->{id};
                my $method  = $request->{method};

                bless $request, 'Beekeeper::JSONRPC::Request';
                $request->{_mqtt_prop} = $msg_headers;

                unless (defined $method && $method =~ m/^([\.\w-]+)\.([\w-]+)$/) {
                    log_warn "Received request with invalid method $method";
                    die Beekeeper::JSONRPC::Error->method_not_found;
                }

                my $cb = $worker->{callbacks}->{"req.$1.$2"} || 
                         $worker->{callbacks}->{"req.$1.*"};

                local $client->{caller_id}   = $msg_headers->{'clid'};
                local $client->{caller_addr} = $msg_headers->{'addr'};
                local $client->{auth_data}   = $msg_headers->{'auth'};

                unless (($self->authorize_request($request) || "") eq BKPR_REQUEST_AUTHORIZED) {
                    log_warn "Request $method was not authorized";
                    die Beekeeper::JSONRPC::Error->request_not_authorized;
                }

                unless ($cb) {
                    log_warn "No callback found for received request $method";
                    die Beekeeper::JSONRPC::Error->method_not_found;
                }

                # Execute job
                $cb->($self, $request->{params}, $request);
            };

            if ($@) {
                # Got an exception while executing job
                if (blessed($@) && $@->isa('Beekeeper::JSONRPC::Error')) {
                    # Handled exception
                    $response = $@;
                }
                else {
                    # Unhandled exception
                    log_error $@;
                    $response = Beekeeper::JSONRPC::Error->server_error;
                    # Sending exact error to caller is very handy, but it is also a security risk
                    $response->{error}->{data} = $@ if $self->{_WORKER}->{debug};
                }
            }
            elsif (blessed($result) && $result->isa('Beekeeper::JSONRPC::Error')) {
                # Explicit error response
                $response = $result;
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

                # Request is ack'ed as received just after sending the response. So, if the
                # process is abruptly interrupted here, the broker will send the request to
                # another worker and it will be executed twice! (acking the request just before 
                # processing it may cause unprocessed requests or undelivered responses)

                $self->{_BUS}->publish(
                    topic     => $msg_headers->{'response_topic'},
                    addr      => $msg_headers->{'addr'},
                    payload   => \$json,
                    buffer_id => 'response',
                );

                if (exists $msg_headers->{'packet_id'}) {

                    $self->{_BUS}->puback(
                        packet_id => $msg_headers->{'packet_id'},
                        buffer_id => 'response',
                    );
                }
                else {
                    # Should not happen (clients must publish with QoS 1)
                    log_warn "Request published with QoS 0 to " . $msg_headers->{'topic'};
                }

                $self->{_BUS}->flush_buffer( buffer_id => 'response' );
            }
            else {

                # Background jobs doesn't expect responses

                $self->{_BUS}->puback(
                    packet_id => $msg_headers->{'packet_id'},
                );
            }
        }

        redo DRAIN if (@{$worker->{job_queue_high}} || @{$worker->{job_queue_low}});

        # Execute tasks postponed until job queue is empty
        if (exists $worker->{postponed}) {
            $_->() foreach @{$worker->{postponed}};
            delete $worker->{postponed};
        }
    }

    $_TASK_QUEUE_DEPTH--;

    # Measure time elapsed since request reception till 
    $worker->{busy_time} += Time::HiRes::time - $worker->{busy_since};
    $worker->{busy_since} = 0;

    $worker->{queued_tasks} = 0;
}


sub stop_accepting_notifications {
    my ($self, @methods) = @_;

    croak "No method specified" unless @methods;

    foreach my $fq_meth (@methods) {

        $fq_meth =~ m/^  ( [\w-]+ (?: \.[\w-]+ )* ) 
                      \. ( [\w-]+ | \* ) $/x or croak "Invalid method $fq_meth";

        my ($service, $method) = ($1, $2);

        my $worker = $self->{_WORKER};

        unless (defined $worker->{callbacks}->{"msg.$fq_meth"}) {
            carp "Not previously accepting notifications $fq_meth";
            next;
        }

        my $local_bus = $self->{_BUS}->{cluster};

        my $topic = "msg/$local_bus/$service/$method";
        $topic =~ tr|.*|/#|;

        # Cannot remove callbacks right now, as new notifications could be in flight or be 
        # already queued. We must wait for unsubscription completion, and then until the 
        # notification queue is empty to ensure that all received ones were processed. And 
        # even then wait a bit more, as some brokers may send messages *after* unsubscription.
        my $postpone = sub {

            $worker->{_timers}->{"unsub-$topic"} = AnyEvent->timer( 
                after => UNSUBSCRIBE_LINGER, cb => sub {

                    delete $worker->{callbacks}->{"msg.$fq_meth"};
                    delete $worker->{_timers}->{"unsub-$topic"};
                }
            );
        };

        $self->{_BUS}->unsubscribe(
            topic       => $topic,
            on_unsuback => sub {
                my ($success, $prop) = @_;

                #TODO: Report caller of stop_accepting_notifications method
                warn "Could not unsubscribe from $topic" unless $success; 

                my $postponed = $worker->{postponed} ||= [];
                push @$postponed, $postpone;

                AnyEvent::postpone { $self->__drain_task_queue };
            }
        );
    }
}


sub stop_accepting_jobs {
    my ($self, @methods) = @_;

    croak "No method specified" unless @methods;

    foreach my $fq_meth (@methods) {

        $fq_meth =~ m/^  ( [\w-]+ (?: \.[\w-]+ )* ) 
                      \. ( [\w-]+ | \* ) $/x or croak "Invalid method $fq_meth";

        my ($service, $method) = ($1, $2);

        unless ($method eq '*') {
            # Known limitation. As all calls for an entire service class are received
            # through a single MQTT subscription (in order to load balance them), it is 
            # not possible to reject a single method. A workaround is to use a different
            # class for each method that need to be individually rejected.
            croak "Cannot cancel individual job subscription to $fq_meth";
        }

        my $worker    = $self->{_WORKER};
        my $callbacks = $worker->{callbacks};

        my @cb_keys = grep { $_ =~ m/^req.\Q$service\E\b/ } keys %$callbacks;

        unless (@cb_keys) {
            #TODO: BUG: carp reports caller as Beekeeper/WorkerPool.pm line 440
            carp "Not previously accepting jobs $fq_meth";
            next;
        }

        my $local_bus = $self->{_BUS}->{cluster};

        my $topic = "\$share/BKPR/req/$local_bus/$service";
        $topic =~ tr|.*|/#|;

        # Cannot remove callbacks right now, as new jobs could be in flight or be already 
        # queued. We must wait for unsubscription completion, and then until the job queue 
        # is empty to ensure that all received jobs were processed. And even then wait a
        # bit more, as some brokers may send jobs *after* unsubscription.
        my $postpone = sub {

            $worker->{_timers}->{"unsub-$topic"} = AnyEvent->timer( 
                after => UNSUBSCRIBE_LINGER, cb => sub {

                    delete $worker->{callbacks}->{$_} foreach @cb_keys;
                    delete $worker->{subscriptions}->{$service};
                    delete $worker->{_timers}->{"unsub-$topic"};

                    # When shutting down tell _work_forever to stop
                    $worker->{stop_cv}->end if $worker->{shutting_down};
                }
            );
        };

        $self->{_BUS}->unsubscribe(
            topic        => $topic,
            on_unsuback  => sub {
                my ($success, $prop) = @_;

                #TODO: Report caller of stop_accepting_jobs method
                warn "Could not unsubscribe from $topic" unless $success; 

                my $postponed = $worker->{postponed} ||= [];
                push @$postponed, $postpone;

                AnyEvent::postpone { $self->__drain_task_queue };
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

    if ($self->{_BUS}->{is_connected}) {
        $self->{_BUS}->disconnect;
    }
}


sub stop_working {
    my ($self, %args) = @_;

    my $worker = $self->{_WORKER};

    # This is the default handler for TERM signal

    unless (exists $worker->{stop_cv}) {
        # Worker did not completed initialization yet
        CORE::exit(0);
    }

    my %services;
    foreach my $fq_meth (keys %{$worker->{callbacks}}) {
        next unless $fq_meth =~ m/^req\.(?!_sync)(.*)\./;
        $services{$1} = 1;
    }

    unless (keys %services) {
        $worker->{stop_cv}->send;
        return;
    }

    $worker->{shutting_down} = 1;

    # Cannot exit right now, as some jobs could be in flight or already queued.
    # So tell the broker to stop sending jobs, and exit after the job queue is empty
    foreach my $service (keys %services) {

        $worker->{stop_cv}->begin;

        $self->stop_accepting_jobs( $service . '.*' );
    }
}


sub __report_status {
    my $self = shift;

    my $worker = $self->{_WORKER};
    my $client = $self->{_CLIENT};

    my $now = Time::HiRes::time;
    my $period = $now - ($worker->{last_report} || ($now - 1));

    $worker->{last_report} = $now;

    # Average jobs per second
    my $jps = sprintf("%.2f", $worker->{jobs_count} / $period);
    $worker->{jobs_count} = 0;

    # Average notifications per second
    my $nps = sprintf("%.2f", $worker->{notif_count} / $period);
    $worker->{notif_count} = 0;

    # Average load as percentage of wall clock busy time (not cpu usage)
    my $load = sprintf("%.2f", $worker->{busy_time} / $period * 100);
    $worker->{busy_time} = 0;

    #ENHACEMENT: report handled and unhandled errors count

    # Queues
    my %queues;
    foreach my $queue (keys %{$worker->{callbacks}}) {
        next unless $queue =~ m/^req\.(?!_sync)(.*)\./;
        $queues{$1} = 1;
    }

    local $client->{auth_data} = $AUTH_TOKENS{'BKPR_SYSTEM'};
    local $client->{caller_id};

    # Tell any supervisor our stats
    $self->do_background_job(
        method => '_bkpr.supervisor.worker_status',
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

    return unless $self->{_BUS}->{is_connected};

    my $worker = $self->{_WORKER};
    my $client = $self->{_CLIENT};

    local $client->{auth_data} = $AUTH_TOKENS{'BKPR_SYSTEM'};
    local $client->{caller_id};

    $self->do_background_job(
        method => '_bkpr.supervisor.worker_exit',
        params => {
            class => ref($self),
            host  => $worker->{hostname},
            pool  => $worker->{pool_id},
            pid   => $$,
        },
    );
}

1;

__END__

=pod

=encoding utf8

=head1 NAME

Beekeeper::Worker - Base class for creating services

=head1 VERSION

Version 0.03

=head1 SYNOPSIS

  package MyApp::Worker;
  
  use Beekeeper::Worker ':log';
  use base 'Beekeeper::Worker';
  
  sub on_startup {
      my $self = shift;
      
      $self->accept_notifications(
          'myapp.msg' => 'got_message',
      );
      
      $self->accept_jobs(
          'myapp.sum' => 'do_sum',
      );
  
      log_debug 'Ready';
  }
  
  sub authorize_request {
      my ($self, $req) = @_;
  
      return BKPR_REQUEST_AUTHORIZED;
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

=head1 METHODS

=head1 CONSTRUCTOR

C<Beekeeper::Worker> objects are created automatically by C<Beekeeper::WorkerPool>
after spawning new processes.

=head1 METHODS

=head3 on_startup

This method is executed on a fresh worker process immediately after it was spawned.
The connection to the broker was just stablished and the logger was initialized.

It is placeholder intended to be overrided in subclasses, which in their implementation
perform startup tasks and declare which job methods and notifications will be handled.

This is the place to initialize, for example, persistent database or cache connections.

After this method returns the worker will wait for incoming events to handle.

=head3 on_shutdown

This method is executed just before a worker process is stopped.

It can be overrided as needed, the default implementation does nothing.

=head3 authorize_request( $req )

This method MUST be overrided in your worker classes, as the default behavior is
to deny the execution of any request.

When a request is received this method is called before executing the corresponding
callback, and it must return the exported constant C<BKPR_REQUEST_AUTHORIZED> in order to
authorize it. Returning any other value will result in the request being ignored. 

This is the place to handle application authentication and authorization.

=head3 log_handler

By default, all workers use a C<Beekeeper::Logger> logger which logs errors and
warnings to files and also to a topic on the message bus. The command line tool
C<bkpr-log> allows to inspect in real time the logs of the entire system. 

To replace this default log mechanism for another one of your choice, you must 
override the class C<log_handler> method and make that return an object implementing
a C<log> method.

For convenience you can import the ':log' symbols and expose to your class the
functions C<log_fatal>, C<log_alert>, C<log_critical>, C<log_error>, C<log_warn>, 
C<log_warning>, C<log_notice>, C<log_info>, C<log_debug> and C<log_trace>.

These will call the underlying C<log> method of your logger class, if the severity
is equal or higher than C<$Beekeeper::Worker::LogLevel>, which is set to allow 
warnings by default. You can increase the log level to include debug info with 
the --debug option of C<bkpr>, or from class config in file pool.config.json.

Using these functions makes very easy to switch logging backends at a later date.

All warnings and errors generated by the execution of the worker code are
logged, unless you specifically catch and ignore them.

=head3 Client methods

In order to make RPC calls to another services, methods C<send_notification>, 
C<call_remote>, C<do_async_job>, C<do_background_job> and C<wait_all_jobs> are 
automatically imported from C<Beekeeper::Client>.

=head3 accept_notifications ( $method => $callback, ... )

Make this worker start accepting specified notifications from message bus.

C<$method> is a string with the format "{service_class}.{method}". A default
or fallback handler can be specified using a wildcard as "{service_class}.*".

C<$callback> is a method name or a coderef that will be called when a notification
is received. When executed, the callback will receive two parameters C<$params> 
(which contains the notification data itself) and C<$req> which is a
C<Beekeeper::JSONRPC::Notification> object (usually redundant unless you need to
inspect request headers).

Notifications are not expected to return a value, any value returned from its
callback is ignored.

The callback is executed within an eval block, if it dies the error will be logged
but otherwise the worker will continue running.

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

=head3 accept_jobs ( $method => $callback, ... )

Make this worker start accepting specified RPC requests from message bus.

C<$method> is a string with the format "{service_class}.{method}". A default
or fallback handler can be specified using a wildcard as "{service_class}.*".

C<$callback> is a method name or a coderef that will be called when a request
is received. When executed, the callback will receive two parameters C<$params> 
(which contains the notification data itself) and C<$req> which is a
C<Beekeeper::JSONRPC::Request> object (usually redundant unless you need to
inspect request headers).

The value or data ref returned by the callback will be sent back to the caller
as response.

The callback is executed within an eval block, if it dies the error will be 
logged but otherwise the worker will continue running, and the caller will 
receive a generic error response.

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

=head3 stop_accepting_notifications ( $method, ... )

Make this worker stop accepting specified notifications from message bus.

C<$method> must be one of the strings used previously in C<accept_notifications>.

=head3 stop_accepting_jobs ( $method, ... )

Make this worker stop accepting specified RPC requests from message bus.

C<$method> must be one of the strings used previously in C<accept_jobs>.

=head3 stop_working 

Make this worker stop processing RPC requests and exit. Unprocessed jobs will 
be resent to another worker by the message broker, unprocessed notifications
will be ignored.

This is the default signal handler for TERM signal. If this method is called
manually WorkerPool will immediately respawn the worker again after it exits.

=head1 SEE ALSO
 
L<Beekeeper::Client>, L<Beekeeper::WorkerPool>, L<Beekeeper::Logger>.

=head1 AUTHOR

José Micó, C<jose.mico@gmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2015-2021 José Micó.

This is free software; you can redistribute it and/or modify it under the same 
terms as the Perl 5 programming language itself.

This software is distributed in the hope that it will be useful, but it is 
provided “as is” and without any express or implied warranties. For details, 
see the full text of the license in the file LICENSE.

=cut
