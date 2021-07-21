package MyApp::Test;

use strict;
use warnings;

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';


sub authorize_request {
    my ($self, $req) = @_;

    return BKPR_REQUEST_AUTHORIZED;
}

sub on_startup {
    my $self = shift;

    $self->accept_remote_calls(
        'myapp.test.echo' => 'echo',
    );

    $self->accept_notifications(
        'myapp.test.msg' => 'message',
    );

    log_info "Ready";
}

sub on_shutdown {
    my $self = shift;

    log_info "Stopped";
}


sub echo {
    my ($self, $params) = @_;

    return $params;
}

sub message {
    my ($self, $params) = @_;
}

1;

