use v5.14;
use warnings;

package RDF::Blank 0.001 {
	use Moose;
	use Data::UUID;
	
	has 'ntriples_string'	=> (is => 'ro', isa => 'Str', lazy => 1, builder => '_ntriples_string');
	
	with 'RDF::API::Term';
	with 'RDF::BlankOrIRI';

	around BUILDARGS => sub {
		my $orig 	= shift;
		my $class	= shift;
		
		if (scalar(@_) == 0) {
			my $uuid	= Data::UUID->new->create_hex;
			return $class->$orig(value => $uuid);
		} elsif (scalar(@_) == 1) {
			return $class->$orig(value => shift);
		}
		return $class->$orig(@_);
	};
	
	sub _ntriples_string {
		my $self	= shift;
		return '_:' . $self->value;
	}
}

1;
