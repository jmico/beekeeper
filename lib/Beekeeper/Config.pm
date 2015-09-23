package Beekeeper::Config;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME
 
Beekeeper::Config - Read configuration files
 
=head1 VERSION
 
Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=over 4

=item get_bus_config


=item get_pool_config


=item read_config_file


=back

=cut

use JSON::XS;

my %Cache;


sub get_bus_config {
    my ($class, $bus_id) = @_;

    my $config = Beekeeper::Config->read_config_file( "bus.config.json" );

    my %bus_cfg  = map { $_->{'bus-id'}  => $_ } @$config;

    return ($bus_id eq '*') ? \%bus_cfg : $bus_cfg{$bus_id};
}

sub get_pool_config {
    my ($class, $pool_id) = @_;

    my $config = Beekeeper::Config->read_config_file( "pool.config.json" );

    my %pool_cfg = map { $_->{'pool-id'} => $_ } @$config;

    return ($pool_id eq '*') ? \%pool_cfg : $pool_cfg{$pool_id};
}

sub read_config_file {
    my ($class, $file) = @_;

    my $cdir; #TODO
    #my $cdir = $self->{options}->{'config-dir'};
    $cdir = $ENV{'BEEKEEPER_CONFIG_DIR'} unless ($cdir && -d $cdir);
    $cdir = '~/.config/beekeeper' unless ($cdir && -d $cdir);
    $cdir = '/etc/beekeeper' unless ($cdir && -d $cdir);

    $file = "$cdir/$file";

    return $Cache{$file} if exists $Cache{$file};

    local($/);
    open(my $fh, '<', $file) or die "Couldn't read config file $file: $!";
    my $data = <$fh>;
    close($fh);

    # Allow comments and end-comma
    my $json = JSON::XS->new->relaxed;

    my $config = eval { $json->decode($data) };

    if ($@) {
        my $errmsg = $@; $errmsg =~ s/(.*) at .*? line \d+/$1/s; #TODO
        die "Couldn't parse config file $file: Invalid JSON syntax: $errmsg";
    }

    $Cache{$file} = $config;

    return $config;
}

1;

=head1 AUTHOR

José Micó, C<< <jose.mico@gmail.com> >>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by José Micó.

This is free software; you can redistribute it and/or modify it under the same 
terms as the Perl 5 programming language itself.

This software is distributed in the hope that it will be useful, but it is 
provided “as is” and without any express or implied warranties. For details, 
see the full text of the license in the file LICENSE.

=cut
