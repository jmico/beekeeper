use strict;
use warnings;

use Test::More;

plan tests => 12;

BEGIN {

    use_ok $_ for qw(
        Beekeeper
        Beekeeper::JSONRPC
        Beekeeper::Bus::STOMP
        Beekeeper::Config
        Beekeeper::Logger
        Beekeeper::Client
        Beekeeper::Worker
        Beekeeper::WorkerPool::Daemon
        Beekeeper::WorkerPool
        Beekeeper::Worker::Util
        Beekeeper::Service::Supervisor::Worker
        Beekeeper::Service::Sinkhole::Worker
    );
}

diag( "Testing Beekeeper $Beekeeper::VERSION, Perl $]" );
