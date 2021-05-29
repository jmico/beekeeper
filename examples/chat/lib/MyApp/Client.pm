package MyApp::Client;

use strict;
use warnings;

use AnyEvent::Impl::Perl;
use MyApp::Service::Chat;
use MyApp::Service::Auth;

use Beekeeper::Client;

my $Help = "Available commands:
  /login username pass   Login
  /pm username message   Send private message
  /logout                End user session
  /kick user             End another user session
  /ping                  Measure latency
  /quit                  Exit (or use Ctrl-C)
";

sub new {
    my ($class, %args) = @_;
    my $self = {};

    $self->{fh} = $args{'fh'} || \*STDIN;
    binmode STDOUT, ":utf8";
    binmode STDIN,  ":utf8";

    #TODO: Read frontend connection parameters from config file

    # Connect to bus 'frontend', wich will forward requests to 'backend'
    $self->{client} = Beekeeper::Client->instance(
        bus_id     => "frontend",
        forward_to => "backend",
        host       => "localhost",
        port       =>  8001,
        username   => "frontend",
        password   => "abc123",
    );

    $self->{chat} = MyApp::Service::Chat->new;
    $self->{auth} = MyApp::Service::Auth->new;

    bless $self, $class;
}

sub run {
    my $self = shift;

    print $Help;

    $self->{chat}->receive_messages( callback => sub {
        my %msg = @_;
        print "> ";
        print $msg{from} . ": " if $msg{from};
        print $msg{message} . "\n";
    });
 
    $self->{hdl} = AnyEvent::Handle->new( fh => $self->{fh} );

    $self->{auth}->login( username => getpwuid($>), password => '123' );

    $self->read_line;

    $self->{quit_cv} = AnyEvent->condvar;
    $self->{quit_cv}->recv;
}

sub read_line {
    my $self = shift;

    $self->{hdl}->push_read( line => sub {
        my ($hdl, $line) = @_;
        print "\033[1A\033[K";  # move one line up and clear it
        eval { $self->process_cmd($line) };
        if ($@) { print "Error: $@" }
        $self->read_line;
    });
}

sub process_cmd {
    my ($self, $line) = @_;

    chomp $line;

    my $chat = $self->{chat};
    my $auth = $self->{auth};
    my $resp;

    return unless (length $line);

    if ($line =~ m|^/login \s+ (\w+) \s+ (\w+)|ix) {

        $resp = $auth->login( username => $1, password => $2 );
    }
    elsif ($line =~ m|^/kick \s+ (\w+)|ix) {

        $resp = $auth->kick( username => $1 );
    }
    elsif ($line =~ m|^/logout\b|i) {

        $resp = $auth->logout;
    }
    elsif ($line =~ m|^/pm \s+ (\w+) \s+ (.+)|ix) {

        $resp = $chat->send_private_message( to_user => $1, message => $2 );
    }
    elsif ($line =~ m|^/ping\b|i) {

        $resp = $chat->ping;
        print "> Ping: $resp ms\n";
        return;
    }
    elsif ($line =~ m|^/quit\b|i) {
        $self->{quit_cv}->send;
        return;
    }
    else {
        $resp = $chat->send_message( message => $line );
    }

    unless ($resp->success) {
        print "ERR: " . $resp->message . "\n";
    }
}

1;
