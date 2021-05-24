package Tests::Recursion;

use strict;
use warnings;

use base 'Tests::Service::Base';

use Test::More;
use Time::HiRes 'sleep';

use constant TOUT => 10;


sub start_test_workers : Test(startup => 1) {
    my $self = shift;

    my $running = $self->start_workers('Tests::Service::Worker', workers_count => 11);
    is( $running, 11, "Spawned 11 workers");
};

sub test_01_recursion : Test(11) {

    my $cli = Beekeeper::Client->instance;
    my $resp;

    # Triangular number sequence
    my @triangular = ( 0, 1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 66, 78 ); 

    # No recursion

    $resp = $cli->do_job(
        method  => 'test.triang',
        params  => 1,
        timeout => TOUT,
    );

    is( $resp->result, 1, "triangular(1)");

    # 1 level of recursion

    $resp = $cli->do_job(
        method  => 'test.triang',
        params  => 2,
        timeout => TOUT,
    );

    is( $resp->result, 3, "triangular(2)");

    for (my $i = 3; $i <= 11; $i++) {

        $resp = $cli->do_job(
            method  => 'test.triang',
            params  => $i,
            timeout => TOUT,
        );

        is( $resp->result, $triangular[$i], "triangular($i)");
    }

    # TODO: fail with 11
}

sub test_02_recursion : Test(4) {
    my $self = shift;

    my $cli = Beekeeper::Client->instance;
    my $resp;

    # No recursion

    $resp = $cli->do_job(
        method  => 'test.fib1',
        params  => 1,
        timeout => TOUT,
    );

    is( $resp->result, 1, "fib(1)");

    $resp = $cli->do_job(
        method  => 'test.fib2',
        params  => 1,
        timeout => TOUT,
    );

    is( $resp->result, 1, "fib(1)");

    # 1 level of recursion

    $resp = $cli->do_job(
        method  => 'test.fib1',
        params  => 2,
        timeout => TOUT,
    );

    is( $resp->result, 1, "fib(2)");

    $resp = $cli->do_job(
        method  => 'test.fib2',
        params  => 2,
        timeout => TOUT,
    );

    is( $resp->result, 1, "fib(2)");
}

sub test_03_recursion : Test(4) {
    my $self = shift;

    my $cli = Beekeeper::Client->instance;

    my @fib = (0,1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144);

    for (my $i = 3; $i <= 4; $i++) { # should handle up to fib(10) with proper load balance

        my $resp = $cli->do_job(
            method  => 'test.fib1',
            params  => $i,
            timeout => TOUT,
        );

        is( $resp->result, $fib[$i], "fib($i)");
    }

    for (my $i = 3; $i <= 4; $i++) { # should handle up to fib(5) with proper load balance

        my $resp = $cli->do_job(
            method  => 'test.fib2',
            params  => $i,
            timeout => TOUT,
        );

        is( $resp->result, $fib[$i], "fib($i)");
    }
}

sub test_04_client_api : Test(7) {
    my $self = shift;

    use_ok('Tests::Service::Client');

    my $svc = 'Tests::Service::Client';
    my $resp;

    $resp = $svc->fibonacci_1( 4 );

    isa_ok($resp, 'Beekeeper::JSONRPC::Response');
    is( $resp->success, 1 );
    is( $resp->result, 3, "fib(4)");


    $resp = $svc->fibonacci_2( 4 );

    isa_ok($resp, 'Beekeeper::JSONRPC::Response');
    is( $resp->success, 1 );
    is( $resp->result, 3, "fib(4)");
}

1;
