package MyApp::Service::AdServer;

use strict;
use warnings;

use Beekeeper::Worker;
use base 'Beekeeper::Worker';


sub on_startup {
    my $self = shift;

    $self->{push_ads_tmr} = AnyEvent->timer(
        interval => 20, 
        cb       => sub { $self->push_ads },
    );
}

sub push_ads {
    my $self = shift;

    $self->send_notification(
        method => "myapp.adserver.ads",
        params => { msg => "This software is adware" },
    );
}

1;
