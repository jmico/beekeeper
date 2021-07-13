package Beekeeper::Worker::Extension;

use strict;
use warnings;

our $VERSION = '0.07';

use Beekeeper::Worker::Extension::SharedCache;

use Exporter 'import';

our @EXPORT = qw( shared_cache );


sub shared_cache {
    my ($self, %args) = @_;

    my $shared = Beekeeper::Worker::Extension::SharedCache->new( worker => $self, %args );

    return $shared;
}

1;

__END__

=pod

=encoding utf8

=head1 NAME
 
Beekeeper::Worker::Extension - Extensions for worker classes
 
=head1 VERSION
 
Version 0.07

=head1 SYNOPSIS

  use Beekeeper::Worker::Extension 'shared_cache';
  
  my $c = $self->shared_cache( ... );
  
  $c->set( $key => $value );
  $c->get( $key );
  $c->delete( $key );

=head1 SEE ALSO
 
L<Beekeeper::Worker::Extension::SharedCache>

=head1 AUTHOR

José Micó, C<jose.mico@gmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2015-2021 José Micó.

This is free software; you can redistribute it and/or modify it under the same 
terms as the Perl 5 programming language itself.

This software is distributed in the hope that it will be useful, but it is 
provided “as is” and without any express or implied warranties. For details, 
see the full text of the license in the file LICENSE.

=cut
