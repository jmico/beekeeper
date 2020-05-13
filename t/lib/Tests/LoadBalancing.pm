package Tests::LoadBalancing;

use strict;
use warnings;

use base 'Tests::Service::Base';

use Test::More;
use Time::HiRes 'sleep';


sub start_test_workers : Test(startup => 1) {
    my $self = shift;

    my $running = $self->start_workers('Tests::Service::Cache', workers_count => 5);
    is( $running, 5, "Spawned 5 workers");
};

sub test_01_load_balancing : Test(5) {
    my $self = shift;

    my $cli = Beekeeper::Client->instance;
    my $resp;

    my $tasks = 500;
    my $workers = 5;
    my $expected = $tasks / $workers;

    for (1..$tasks) {
        $cli->do_background_job(
            method  => 'cache.bal',
        );
    }

    $resp = $cli->do_job(
        method  => 'cache.raw',
    );

    my $runs = $resp->result;

    foreach my $pid (sort keys %$runs) {
        my $got = $runs->{$pid};
        my $offs = $got - $expected;
        my $dev = abs( $offs / $expected * 100 );

        # diag "$pid: $got  $offs  $dev %";

        cmp_ok($dev,'<', 15, "expected $expected runs, got $got");
    }
}

1;
