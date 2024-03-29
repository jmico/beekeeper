package MyClient;

use strict;
use warnings;

use Beekeeper::Client;


sub uppercase {
    my ($class, $str) = @_;

    my $client = Beekeeper::Client->instance;

    my $resp = $client->call_remote(
        method => 'myapp.str.uc',
        params => { string => $str },
    );

    return $resp->result;
}

1;
