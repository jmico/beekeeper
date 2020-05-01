package MyApp::Service::Chat;

use strict;
use warnings;

use Beekeeper::Client;


sub message {
    my ($self, %args) = @_;

    my $expr = $params->{"expr"};

    Beekeeper::Client->instance->do_job(
        method => 'myapp.chat.message',
        params => { message => $args },
    )

    return $result;
}

1;
