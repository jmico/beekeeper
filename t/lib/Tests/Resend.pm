package Tests::Resend;

use strict;
use warnings;

use base 'Tests::Service::Base';

use Test::More;
use Time::HiRes 'sleep';

use constant DEBUG => 0;


sub start_test_workers : Test(startup => 3) {
    my $self = shift;

    my @pids = $self->start_workers('Tests::Service::Worker', workers_count => 2);
    is( scalar @pids, 2, "Spawned 2 workers");

    $self->stop_workers('INT', @pids);

    my $running_1 = kill(0, $pids[0]);
    my $running_2 = kill(0, $pids[1]);

    is($running_1, 0, 'Stopped 1 worker');
    is($running_2, 0, 'Stopped 1 worker');
};

sub test_01_term : Test(21) {
    my $self = shift;

    my $cli = Beekeeper::Client->instance;
    my @req;

    my @worker_pids = $self->start_workers('Tests::Service::Worker', workers_count => 4);

    ## Test that broker resend jobs when workers are stopped with TERM

    for (1..20) {

        for (1..8) {
            # Give them more work than they can do
            push @req, $cli->do_async_job(
                method  => 'test.sleep',
                params  => .5,
                timeout => 20,
            );
        }

        my $old = shift @worker_pids;
        DEBUG && diag "Stopping TERM worker $old";
        kill('TERM', $old);

        my ($new) = $self->start_workers('Tests::Service::Worker', workers_count => 1, no_wait => 1);
        push @worker_pids, $new;

        sleep .5;
        ok(1);
    }

    DEBUG && diag "Waiting for backlog";
    $cli->wait_all_jobs;

    my @ok = grep { $_->success } @req;
    is( scalar(@ok), scalar(@req), "All jobs executed " . scalar(@ok). "/". scalar(@req));
}

sub test_02_int : Test(21) {
    my $self = shift;

    my $cli = Beekeeper::Client->instance;
    my @req;

    my @worker_pids = $self->start_workers('Tests::Service::Worker', workers_count => 4);

    ## Test that broker resend jobs when workers are killed with INT

    for (1..20) {

        for (1..12) {
            # Give them more work than they can do
            push @req, $cli->do_async_job(
                method  => 'test.sleep',
                params  => .5,
                timeout => 20,
            );
        }

        my $old = shift @worker_pids;
        DEBUG && diag "Killing INT worker $old";
        kill('INT', $old);

        my ($new) = $self->start_workers('Tests::Service::Worker', workers_count => 1, no_wait => 1);
        push @worker_pids, $new;

        sleep .5;
        ok(1);
    }

    DEBUG && diag "Waiting for backlog";
    $cli->wait_all_jobs;

    my @ok = grep { $_->success } @req;
    is( scalar(@ok), scalar(@req), "All jobs executed " . scalar(@ok). "/". scalar(@req));
}

1;
