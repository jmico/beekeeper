package MyWorker;

use strict;
use warnings;

use base 'Beekeeper::Worker';


sub on_startup {
    my $self = shift;

    $self->accept_jobs(
        'myapp.str.uc' => 'uppercase',
    );
}

sub uppercase {
    my ($self, $params) = @_;

    my $str = $params->{'string'};

    $str = uc($str);

    return $str;
}

1;
