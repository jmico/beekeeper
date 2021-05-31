package Tests::Service::Config;

use strict;
use warnings;

use JSON::XS;

my $bus_config_json = qq<

# Mock bus.config.json file used by tests

[
    {
        "bus_id"   : "test",
        "host"     : "localhost",
        "port"     :  %PORT%,
        "username" : "test",
        "password" : "abc123",
    },
]>;

my $toybroker_config_json = qq<

# Mock toybroker.config.json file used by tests

[
    {
        "listen_addr" : "127.0.0.1",
        "listen_port" : %PORT%,

        "users" : {
            "test" : { "password" : "abc123" },
        },
    },
]>;

sub read_config_file {
    my ($class, $file) = @_;

    my $data = $file eq "bus.config.json"       ? $bus_config_json       : 
               $file eq "toybroker.config.json" ? $toybroker_config_json : '';

    #TODO: Find an unused port
    my $test_port = 51883;
    $data =~ s/%PORT%/$test_port/;

    # Allow comments and end-comma
    my $json = JSON::XS->new->relaxed;

    my $config = eval { $json->decode($data) };

    return $config;
}

INSTALL: {

    no strict 'refs';
    no warnings 'redefine';

    *{'Beekeeper::Config::read_config_file'} = \&read_config_file;
}
    
1;
