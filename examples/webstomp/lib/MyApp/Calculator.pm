package MyApp::Calculator;

use strict;
use warnings;

use Beekeeper::Client;


sub eval_expr {
    my ($self, $str) = @_;

    my $client = Beekeeper::Client->instance;

    my $resp = $client->do_job(
        method => 'myapp.calculator.eval_expr',
        params => { expr => $str },
    );

    return $resp->result;
}

1;
