package Tests::Service::Base;

use strict;
use warnings;

use Test::Class;
use Test::More;
use base 'Test::Class';

use Beekeeper::Client;
use Beekeeper::Config;
use Beekeeper::Service::Supervisor;
use Time::HiRes;

use constant DEBUG => 0;

=head1 Tests::Beekeeper::Service

Base class for testing services.

=item start_workers ( $worker_class, %config )

Creates a temporary pool of workers in order to test the service.

Note that tests will fail if $worker_class was already used (as in 'use Foo::Worker')
as a proper service client must not depend at all of worker code.

=item stop_workers

Stop all workers. Called automatically when the test ends.

=cut

use Tests::Service::Config;

sub check_broker_connection : Test(startup => 1) {
    my $class = shift;

    # Ensure that tests can connect to broker
    my $config = Beekeeper::Config->get_bus_config( bus_id => 'backend' );
    my $bus = Beekeeper::Bus::STOMP->new( %$config, timeout => 1 );
    eval { $bus->connect( blocking => 1 ) };
    $class->BAILOUT("Could not connect to STOMP broker: $@") if $@;
    $bus->disconnect;
    %$bus = (); undef $bus;
    ok( 1, "Can connect to STOMP broker");
}

sub stop_test_workers : Test(shutdown) {
    my $class = shift;

    # Stop forked workers when test ends
    $class->stop_workers;
}

my @forked_pids;

sub start_workers {
    my ($class, $worker_class, %config) = @_;

    # Check if worker was already used
    my $module_file = $worker_class;
    $module_file =~ s/::/\//g;
    $module_file .= '.pm';
    $class->BAILOUT("$worker_class is already loaded") if $INC{$module_file};

    my $workers_count = $config{workers_count} ||= 2;
    my $running;
 
    unless (@forked_pids) {

        ## First call  

        # Spawn a supervisor
        my $pid = $class->_spawn_worker('Beekeeper::Service::Supervisor::Worker');
        push @forked_pids, $pid;

        # Wait until supervisor is running
        diag "Waiting for supervisor" if DEBUG;
        my $max_wait = 100;
        while ($max_wait--) {
            my $status = Beekeeper::Service::Supervisor->get_services_status( class => 'Beekeeper::Service::Supervisor::Worker' );
            $running = $status->{'Beekeeper::Service::Supervisor::Worker'}->{count} || 0;
            last if $running == 1;
            Time::HiRes::sleep(0.1);
        }

        $SIG{'USR2'} = sub {
            # Send by childs when worker does not compile
            $class->BAILOUT("$worker_class does not compile");
        };
    }

    # Spawn workers
    for (1..$workers_count) {
        my $pid = $class->_spawn_worker($worker_class, %config);
        push @forked_pids, $pid;
    }

    # Wait until workers are running
    diag "Waiting for $workers_count $worker_class workers" if DEBUG;
    my $max_wait = 100;
    while ($max_wait--) {
        my $status = Beekeeper::Service::Supervisor->get_services_status( class => $worker_class );
        $running = $status->{$worker_class}->{count} || 0;
        last if $running == $workers_count;
        Time::HiRes::sleep(0.1);
    }

    return $running;
}

sub stop_workers {
    my $class = shift;

    # Signal all workers to quit
    foreach my $worker_pid (@forked_pids) {
        kill('INT', $worker_pid);
    }

    # Wait until test workers are gone
    diag "Waiting for workers to quit" if DEBUG;
    my $max_wait = 100;
    while (@forked_pids && $max_wait--) {
        @forked_pids = grep { kill(0, $_) } @forked_pids;
        Time::HiRes::sleep(0.1);
    }
};

sub _spawn_worker {
    my ($class, $worker_class, %config) = @_;

    # Mimic Beekeeper::WorkerPool->spawn_worker

    $SIG{CHLD} = 'IGNORE';

    my $parent_pid = $$;
    my $worker_pid = fork;

    die "Failed to fork: $!" unless defined $worker_pid;

    if ($worker_pid) {
        # Parent stops here
        return $worker_pid;
    }

    # Child

    $SIG{CHLD} = 'IGNORE';
    $SIG{INT}  = 'DEFAULT';
    $SIG{TERM} = 'DEFAULT';
    $SIG{HUP}  = 'DEFAULT';

    srand();

    # Destroy inherithed STOMP connection
    if ($Beekeeper::Client::singleton) {
        $Beekeeper::Client::singleton->{_BUS}->{handle}->destroy;
        undef $Beekeeper::Client::singleton;
    }

    # Load worker module
    eval "use $worker_class";

    if ($@) {
        # Worker does not compile
        warn "ERROR: $worker_class does not compile: " . $@;
        kill('USR2', $parent_pid);
        CORE::exit(99);
    };

    # Mocked pool config
    my $pool_config = {
         'daemon_name' => 'test-pool',
         'description' => 'Temp pool used for run tests',
         'pool_id'     => 'test-pool',
         'bus_id'      => 'test',
         'workers'     => { },
    };

    # Mocked worker config
    my $worker_config = {
        #TODO: send log to a file, so it can be inspected 
        log_file => '/dev/null',
        %config
    };

    my $foreground = $config{foreground} || DEBUG;

    my $worker = $worker_class->new(
        pool_config => $pool_config,
        parent_pid  => $parent_pid,
        pool_id     => $pool_config->{pool_id},
        config      => $worker_config,
        foreground  => $foreground,
    );

    $worker->__work_forever;

    CORE::exit;
}

1;
