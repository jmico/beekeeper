package Tests::Service::Config;

use strict;
use warnings;

use JSON::XS;

my $bus_config_json = qq<
[
    # Mock config file used by tests

    {
        "bus-id" : "backend",
        "host"   : "localhost",
        "user"   : "test",
        "pass"   : "abc123",
        "vhost"  : "/test",
    },
    {
        "bus-id" : "frontend-1",
        "host"   : "localhost",
        "user"   : "test",
        "pass"   : "abc123",
        "vhost"  : "/test",
    },
    {
        "bus-id" : "frontend-2",
        "host"   : "localhost",
        "user"   : "test",
        "pass"   : "abc123",
        "vhost"  : "/test",
    },
]>;

sub read_config_file {
    my ($class, %args) = @_;

    my $data = $args{config_file} eq "bus.config.json" ? $bus_config_json : '';

    # Allow comments and end-comma
    my $json = JSON::XS->new->relaxed;

    my $config = eval { $json->decode($data) };

    return $config;
}

INSTALL: {

    no strict 'refs';
    no warnings 'redefine';

    my $old_new = \&{'Beekeeper::Config::read_config_file'};
    *{'Beekeeper::Config::read_config_file'} = \&read_config_file; # sub { $old_new->( @_, config_file => $config_file ) };
}
    
1;
