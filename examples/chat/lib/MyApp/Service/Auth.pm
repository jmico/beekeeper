package MyApp::Service::Auth;

use strict;
use warnings;

use Beekeeper::Client;


sub on_startup {
    my $self = shift;

    $self->accept_jobs(
        'myapp.auth.login' => 'login',
        'myapp.auth.logout' => 'logout',
    );
}

sub login {
    my ($self, $params, $job) = @_;

    my $uname = $params->{username};

    $self->do_job(
        method => "_bkpr.frontend.bind",
        params => {
             address => "frontend.user-$uname",
             queue   =>  $job->{_headers}->{'x-forward-reply'},
        }
    );

    warn "$uname ok! ". $job->{_headers}->{'x-forward-reply'};

    # Create a virtual destination that will be routed to caller queue

    #$self->bind_session( bus => "frontend.user-$uid" );

    #$self->route( "frontend.user-$uid" => $job->sender_address );

    #$self->bind( $job->sender_address => "frontend.user-$uid" );

    #$self->aaa( "frontend.user-$uid" );
}

sub logout {
}

1;
