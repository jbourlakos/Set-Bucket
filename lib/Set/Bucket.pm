package Set::Bucket;

use 5.032000;
use strict;
use warnings;

use Moose;
use MooseX::Types::Moose qw(ArrayRef Int Undef);
use List::Util qw( any sum0 none );
use POSIX qw( ceil floor );
use Carp qw( croak );

require Exporter;
our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use Set::Bucket ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = (
    'all' => [
        qw(

        )
    ]
);

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(

);

our $VERSION = '0.01';

# Preloaded methods go here.

use constant INITIAL_MODULO        => 1;
use constant BUCKET_EFFICIENCY_MIN => 0.75;
use constant MODULO_EFFICIENCY_MIN => 0.75;

has 'buckets' => (
    is       => 'rw',
    isa      => 'ArrayRef[ArrayRef[Int|Undef]|Undef]',
    builder  => '_build_buckets',
    clearer  => '_clear_buckets',
    init_arg => undef,
    lazy     => 1,
    required => 1,
    writer   => '_buckets',
);

has 'modulo' => (
    is       => 'rw',
    isa      => 'Int',
    default  => sub { INITIAL_MODULO },
    init_arg => undef,
    required => 1,
    writer   => '_modulo',
);

has 'size' => (
    is       => 'rw',
    isa      => 'Int',
    builder  => '_build_size',
    clearer  => '_clear_size',
    init_arg => undef,
    required => 1,
    writer   => '_size',
);

sub _build_buckets {
    my ($self) = @_;
    my $modulo = $self->modulo;
    my $result = [];
    for my $idx ( 0, $modulo - 1 ) {
        $result->[$idx] = [];
    }
    return $result;
}

sub _build_size { 0 }

sub _increment {
    my ($self) = @_;
    my $size = $self->size // 0;
    $self->_size( $size + 1 );
}

sub _decrement {
    my ($self) = @_;
    my $size = $self->size // 0;
    $self->_size( $size - 1 );
}

sub _insert_single_element {
    my ( $self, $new_elem ) = @_;
    return unless defined($new_elem);
    my $buckets = $self->buckets;
    my $modulo  = $self->modulo;
    push @{ $buckets->[ $new_elem % $modulo ] }, $new_elem;
    $self->_increment;
}

sub insert {
    my ( $self, @args ) = @_;

    my $new_elem_count = 0;
    my $bf_ceil        = ceil( $self->balance_factor ) || 1;
    for my $new_elem (@args) {
        next unless defined($new_elem);

        $self->_insert_single_element($new_elem);

        # at every bf amount of elems, check for rehash
        if ( $new_elem_count % $bf_ceil == 0 && $self->_need_rehash ) {
            $self->_rehash;
            $bf_ceil = ceil( $self->balance_factor ) || 1;
        }
        $new_elem_count += 1;
    }

    return $self;
}

sub contains {
    my ( $self, $elem ) = @_;
    my $buckets = $self->buckets;
    my $modulo  = $self->modulo;

    my $elem_bucket = $buckets->[ $elem % $modulo ];

    return any { $_ == $elem } @$elem_bucket;
}

sub balance_factor {
    my ($self) = @_;
    return ( $self->size / $self->modulo );
}

sub _dot_product {
    my ( $self, $vector_1, $vector_2 ) = @_;
    my $dot_product = sum0
      map { ( $vector_1->[$_] // 0 ) * ( $vector_2->[$_] // 0 ) }
      ( 0 .. $self->modulo - 1 );
    return $dot_product;
}

sub _euclidean_norm {
    my ( $self, $vector ) = @_;
    my $euclidean_norm = sqrt sum0 map { defined($_) ? $_ * $_ : 0 } @$vector;
    return $euclidean_norm;
}

sub _cosine_similarity {
    my ( $self, $vector_1, $vector_2 ) = @_;
    my $eucl_norm_1 = $self->_euclidean_norm($vector_1);
    my $eucl_norm_2 = $self->_euclidean_norm($vector_2);
    return $self->_dot_product( $vector_1, $vector_2 ) /
      ( $eucl_norm_1 * $eucl_norm_2 );
}

sub _bucket_balance_vector {
    my ($self)                = @_;
    my $modulo                = $self->modulo;
    my $buckets               = $self->buckets;
    my @bucket_balance_vector = map { defined($_) ? scalar(@$_) : 0 } @$buckets;
    return \@bucket_balance_vector;
}

sub _balance_factor_vector {
    my ($self)                = @_;
    my $modulo                = $self->modulo;
    my $balance_factor        = $self->balance_factor;
    my @balance_factor_vector = map { $balance_factor } ( 1 .. $modulo );
    return \@balance_factor_vector;
}

sub bucket_efficiency {
    my ($self) = @_;
    my $balance_factor = $self->balance_factor;
    if ( $balance_factor == 0 ) {
        return 1;
    }
    return $self->_cosine_similarity(
        $self->_bucket_balance_vector,
        $self->_balance_factor_vector,
    );
}

sub modulo_efficiency {
    my ($self)         = @_;
    my $modulo         = $self->modulo;
    my $balance_factor = $self->balance_factor;

    # the rectangle of [bf, modulo] should tend to be square
    my $ideal_value = sqrt( $modulo * $balance_factor );

    # the modulo should be as close to ideal as possible
    return ( $modulo / $ideal_value );
}

sub _need_rehash {
    my ($self) = @_;
    if ( $self->modulo_efficiency < MODULO_EFFICIENCY_MIN ) {
        return 1;
    }
    if ( $self->bucket_efficiency < BUCKET_EFFICIENCY_MIN ) {
        return 1;
    }
    return 0;
}

sub _rehash {
    my ($self) = @_;

    # store current buckets
    my $old_buckets        = $self->buckets;
    my $old_modulo         = $self->modulo;
    my $old_balance_factor = $self->balance_factor;

    # clear instance
    $self->_clear_buckets;
    $self->_clear_size;

    # adjust instance
    my $new_modulo = ceil( ( $old_modulo + $old_balance_factor ) / 2 );
    $self->_modulo($new_modulo);

    # re-include values
    for my $old_bucket (@$old_buckets) {
        next unless defined($old_bucket);
        for my $elem (@$old_bucket) {
            $self->_insert_single_element($elem);
        }
    }
    return $self;
}

sub _debug_info {
    my ($self) = @_;
    return [
        { modulo                => $self->modulo },
        { size                  => $self->size },
        { bucket_balance_vector => $self->_bucket_balance_vector },
        { balance_factor_vector => $self->_balance_factor_vector },
        {
            bucket_balance_vector_eucl =>
              $self->_euclidean_norm( $self->_bucket_balance_vector )
        },
        {
            balance_factor_vector_eucl =>
              $self->_euclidean_norm( $self->_balance_factor_vector )
        },
        {
            dot_product => $self->_dot_product(
                $self->_bucket_balance_vector,
                $self->_balance_factor_vector,
            )
        },
        {
            bucket_efficiency =>
              [ $self->bucket_efficiency, '>=', BUCKET_EFFICIENCY_MIN ]
        },
        {
            modulo_efficiency =>
              [ $self->modulo_efficiency, '>=', MODULO_EFFICIENCY_MIN ]
        },
        { need_rehash => $self->_need_rehash },
    ];
}

sub to_array {
    my ($self) = @_;
    my $buckets = $self->buckets;
    my @result;
    for my $bucket (@$buckets) {
        for my $value (@$bucket) {
            next unless defined($value);
            push @result, $value;
        }
    }
    return @result;
}

sub except {
    goto \&_except_using_arrays_and_listutil;
}

# 1M*1M => time: ~120.0
sub _except_using_double_for {
    my ( $self, $other_set ) = @_;
    param_exception('Argument is not a set')
      unless blessed($other_set) eq __PACKAGE__;
    my @result_values;
    my $buckets = $self->buckets;
    for my $bucket (@$buckets) {
        for my $value (@$bucket) {
            next if ( $other_set->find($value) );
            push @result_values, $value;
        }
    }
    return @result_values;
}

# 1M*1M => time: ???
sub _except_using_arrays_and_listutil {
    my ( $self, $other_set ) = @_;
    param_exception('Argument is not a set')
      unless blessed($other_set) eq __PACKAGE__;

    my @self_array  = $self->to_array;
    my @other_array = $other_set->to_array;

    my @result;
    @result = grep {
        my $x = $_;
        none { $x == $_ } @other_array
    } @self_array;

    return @result;
}

1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

Set::Bucket - Perl extension for blah blah blah

=head1 SYNOPSIS

  use Set::Bucket;
  blah blah blah

=head1 DESCRIPTION

Stub documentation for Set::Bucket, created by h2xs. It looks like the
author of the extension was negligent enough to leave the stub
unedited.

Blah blah blah.

=head2 EXPORT

None by default.



=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.

If you have a mailing list set up for your module, mention it here.

If you have a web site set up for your module, mention it here.

=head1 AUTHOR

Ioannis Bourlakos, E<lt>jbourlakos@(none)E<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2021 by Ioannis Bourlakos

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.32.0 or,
at your option, any later version of Perl 5 you may have available.


=cut
