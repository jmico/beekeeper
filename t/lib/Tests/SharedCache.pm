package Tests::SharedCache;

use strict;
use warnings;

use base 'Tests::Service::Base';

use Test::More;
use Time::HiRes 'sleep';


sub start_test_workers : Test(startup => 1) {
    my $self = shift;

    my $running = $self->start_workers('Tests::Service::Cache', workers_count => 10);
    is( $running, 10, "Spawned 10 workers");
};

sub test_01_shared_cache_basic : Test(11) {
    my $self = shift;

    my $cli = Beekeeper::Client->instance;
    my $resp;

    $resp = $cli->do_job(
        method  => 'cache.get',
        params  => { key => 'foo' },
    );

    is( $resp->result, undef );

    $resp = $cli->do_job(
        method  => 'cache.set',
        params  => { key => 'foo', val => 67 },
    );

    is( $resp->success, 1 );

    $resp = $cli->do_job(
        method  => 'cache.get',
        params  => { key => 'foo' },
    );

    is( $resp->result, 67 );

    $resp = $cli->do_job(
        method  => 'cache.del',
        params  => { key => 'foo' },
    );

    is( $resp->success, 1 );

    $resp = $cli->do_job(
        method  => 'cache.get',
        params  => { key => 'foo' },
    );

    is( $resp->result, undef );

    $resp = $cli->do_job(
        method  => 'cache.set',
        params  => { key => 'foo', val => 67 },
    );

    is( $resp->success, 1 );

    $resp = $cli->do_job(
        method  => 'cache.set',
        params  => { key => 'foo', val => undef },
    );

    is( $resp->success, 1 );

    $resp = $cli->do_job(
        method  => 'cache.get',
        params  => { key => 'foo' },
    );

    is( $resp->result, undef );

    $resp = $cli->do_job(
        method  => 'cache.set',
        params  => { key => 'foo', val => [ 7, undef, { +bar => 'baz' } ] },
    );

    is( $resp->success, 1 );

    $resp = $cli->do_job(
        method  => 'cache.get',
        params  => { key => 'foo' },
    );

    is_deeply( $resp->result, [ 7, undef, { +bar => 'baz' } ] );

    $resp = $cli->do_job(
        method  => 'cache.set',
        params  => { key => 'foo', val => 48 },
    );

    is( $resp->success, 1 );
}

sub test_02_shared_cache_stress : Test(20) {
    my $self = shift;

    my $cli = Beekeeper::Client->instance;
    my $resp;

    my $Data = { 'foo' => 48 };

    for (1..1000) {

        if (rand() < .8)  {
            # Add entry
            my $key = ''; $key .= ('a'..'z')[rand 26] for (1..4);

            my $val = rand() < .2 ?   int(rand 1000)   :
                      rand() < .2 ? [ int(rand 1000) ] :
                      rand() < .2 ? { int(rand 1000) => int(rand 1000) } :
                      rand() < .1 ?               0    :
                      rand() < .1 ?              ""    : undef;

            $Data->{$key} = $val;
            $resp = $cli->do_job(
                method  => 'cache.set',
                params  => { key => $key, val => $val },
            );
        }
        else {
            # Delete entry
            my @k = keys %$Data;
            next unless @k;
            my $key = $k[rand @k];

            delete $Data->{$key};
            $resp = $cli->do_job(
                method  => 'cache.del',
                params  => { key => $key },
            );
        }
    }

    foreach my $key (keys %$Data) {
        # Setting entries to undef actually acts as delete
        delete $Data->{$key} unless defined $Data->{$key};
    }

    for (1..20) {

        $resp = $cli->do_job(
            method  => 'cache.raw',
        );

        my $Dump = $resp->result;

        foreach my $key (keys %$Dump) {
            # Deleted entries linger for a while
            delete $Dump->{$key} unless defined $Dump->{$key};
        }

        is_deeply($Data, $Dump);
    }
}

1;
