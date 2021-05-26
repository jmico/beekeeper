package Tests::IntSignal;

use strict;
use warnings;

use base 'Tests::Service::Base';

use Test::More;
use Time::HiRes 'sleep';

use constant DEBUG => 0;


sub test_01_int_signal : Test(21) {
    my $self = shift;

    my $cli = Beekeeper::Client->instance;
    my @req;

    my @worker_pids = $self->start_workers('Tests::Service::Worker', workers_count => 4);

    ## Test that broker resend jobs when workers are killed with INT

    for (1..20) {

        for (1..8) {
            # Give them more work than they can do, to ensure that the job queue is full
            push @req, $cli->do_async_job(
                method  => 'test.sleep',
                params  => .5,
                timeout => 30,
            );
        }

        # When workers are killed they are probably running a job that must be resent by the broker
        my $old = shift @worker_pids;
        DEBUG && diag "Killing INT worker $old";
        kill('INT', $old);

        my ($new) = $self->start_workers('Tests::Service::Worker', workers_count => 1, no_wait => 1);
        push @worker_pids, $new;

        sleep 1;
        ok(1);
    }

    DEBUG && diag "Waiting for backlog";
    $cli->wait_all_jobs;

    my @ok = grep { $_->success } @req;
    is( scalar(@ok), scalar(@req), "All jobs executed " . scalar(@ok). "/". scalar(@req));
}

1;
