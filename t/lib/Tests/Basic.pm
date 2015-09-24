package Tests::Basic;

use strict;
use warnings;

use base 'Tests::Service::Base';

use Test::More;
use Time::HiRes 'sleep';


sub start_test_workers : Test(startup => 1) {
    my $self = shift;

    my $running = $self->start_workers('Tests::Service::Worker');
    is( $running, 2, "Spawned 2 workers");
};

sub test_01_notifications : Test(2) {
    my $self = shift;

    my $cli = Beekeeper::Client->instance;
    my $var = 74;

    $SIG{'USR1'} = sub { $var = $var + 1 };

    $cli->send_notification(
        method => "test.signal",
        params => { signal => 'USR1', pid => $$ },
    );

    my $expected = 76;
    my $max_wait = 100; while ($max_wait--) { last if $var == $expected; sleep 0.01; }
    is( $var, $expected, "Notifications received by 2 workers");

    $cli->send_notification(
        method => "test.try_catchall",
        params => { signal => 'USR1', pid => $$ },
    );

    $expected = 78;
    $max_wait = 100; while ($max_wait--) { last if $var == $expected; sleep 0.01; }
    is( $var, $expected, "Catchall notifications received by 2 workers");
}

sub test_02_sync_jobs : Test(12) {
    my $self = shift;
    
    my $cli = Beekeeper::Client->instance;

    my $resp = $cli->do_job(
        method => 'test.echo',
        params => "foo",
    );

    isa_ok($resp, 'Beekeeper::JSONRPC::Response');
    is( $resp->success, 1 );
    is( $resp->result, 'foo');

    $resp = $cli->do_job(
        method => 'test.echo',
        params => [ 1, { a => 2 }, "" ],
    );

    is( $resp->success, 1 );
    is_deeply( $resp->result, [ 1, { a => 2 }, "" ]);

    $resp = $cli->do_job(
        method => 'test.fail',
        params => { 'die' => "error message" },
        raise_error => 0,
    );

    isa_ok($resp, 'Beekeeper::JSONRPC::Error');
    is( $resp->success, 0 );
    is( $resp->code, -32000);
    is( $resp->message, "Server error");
    is( $resp->data, "error message");

    $resp = eval {
        $cli->do_job(
            method => 'test.fail',
            params => { 'die' => "error message" },
        );
    };

    is( $resp, undef );
    like( $@, qr/Call to 'test.fail' failed: Server error: error message/);
}

sub test_03_background_jobs : Test(1) {
    my $self = shift;

    my $cli = Beekeeper::Client->instance;
    my $var = 594;

    $SIG{'USR1'} = sub { $var = $var + 1 };

    for (1..3) {
        $cli->do_background_job(
            method => "test.signal",
            params => { signal => 'USR1', pid => $$ },
        );
    }

    my $expected = 597;
    my $max_wait = 100; while ($max_wait--) { last if $var == $expected; sleep 0.01; }
    is( $var, $expected, "Background job executed 3 times");
}

sub test_04_async_jobs : Test(12) {
    my $self = shift;

    my $cli = Beekeeper::Client->instance;

    my $req = $cli->do_async_job(
        method => 'test.echo',
        params => "baz",
    );

    isa_ok($req, 'Beekeeper::JSONRPC::Request');
    is( $req->response, undef );
    is( $req->success, undef );
    is( $req->result, undef );

    $cli->wait_all_jobs;

    isa_ok( $req->response, 'Beekeeper::JSONRPC::Response' );
    is( $req->success, 1 );
    is( $req->result, "baz" );

    my @reqs;
    my $var = 239;

    foreach my $n (0..4) {
        my $req = $cli->do_async_job(
            method => 'test.echo',
            params => $var + $n,
        );
        push @reqs, $req;
    }

    $cli->wait_all_jobs;

    foreach my $n (0..4) {
        is( $reqs[$n]->result, $var + $n );
    }
}

sub test_05_client_api : Test(5) {
    my $self = shift;

    use_ok('Tests::Service::Client');

    my $svc = 'Tests::Service::Client';
    my $var = 52;

    $SIG{'USR1'} = sub { $var = $var + 1 };

    $svc->notify( "test.signal" => { signal => 'USR1', pid => $$ } );

    my $expected = 54;
    my $max_wait = 100; while ($max_wait--) { last if $var == $expected; sleep 0.01; }
    is( $var, $expected, "Notifications received by 2 workers");


    my $resp = $svc->echo( "foo" );

    isa_ok($resp, 'Beekeeper::JSONRPC::Response');
    is( $resp->success, 1 );
    is( $resp->result, 'foo');
}

1;

