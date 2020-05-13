package Tests::Recursion;

use strict;
use warnings;

use base 'Tests::Service::Base';

use Test::More;
use Time::HiRes 'sleep';


sub start_test_workers : Test(startup => 1) {
    my $self = shift;

    my $running = $self->start_workers('Tests::Service::Worker', workers_count => 11);
    is( $running, 11, "Spawned 11 workers");
};

sub test_01_recursion : Test(17) {
    my $self = shift;

    my $cli = Beekeeper::Client->instance;

    my @fib = (0,1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144);

    for (my $i = 0; $i <= 10; $i++) {

        my $resp = $cli->do_job(
            method  => 'test.fib1',
            params  => $i,
            timeout => 1,
        );

        is( $resp->result, $fib[$i] );
    }

    for (my $i = 0; $i <= 5; $i++) {

        my $resp = $cli->do_job(
            method  => 'test.fib2',
            params  => $i,
            timeout => 1,
        );

        is( $resp->result, $fib[$i] );
    }
}

sub test_02_client_api : Test(7) {
    my $self = shift;

    use_ok('Tests::Service::Client');

    my $svc = 'Tests::Service::Client';
    my $resp;

    $resp = $svc->fibonacci_1( 6 );

    isa_ok($resp, 'Beekeeper::JSONRPC::Response');
    is( $resp->success, 1 );
    is( $resp->result, 8 );


    $resp = $svc->fibonacci_2( 4 );

    isa_ok($resp, 'Beekeeper::JSONRPC::Response');
    is( $resp->success, 1 );
    is( $resp->result, 3 );
}

1;
