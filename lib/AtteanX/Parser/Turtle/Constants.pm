# AtteanX::Parser::Turtle::Constants
# -----------------------------------------------------------------------------

=head1 NAME

AtteanX::Parser::Turtle::Constants - Constant definitions for use in parsing Turtle, TriG, and N-Triples

=head1 VERSION

This document describes AtteanX::Parser::Turtle::Constants version 0.005

=head1 SYNOPSIS

 use AtteanX::Parser::Turtle::Constants;

=head1 METHODS

=over 4

=cut

package AtteanX::Parser::Turtle::Constants 0.005 {
	use v5.14;
	use warnings;

	our $VERSION;
	our @EXPORT;
	BEGIN {
		$VERSION				= 0.005;
		@EXPORT = qw(
			LBRACKET
			RBRACKET
			LPAREN
			RPAREN
			DOT
			SEMICOLON
			COMMA
			HATHAT
			A
			BOOLEAN
			PREFIXNAME
			IRI
			BNODE
			DOUBLE
			DECIMAL
			INTEGER
			WS
			COMMENT
			STRING3D
			STRING3S
			STRING1D
			STRING1S
			BASE
			PREFIX
			SPARQLBASE
			SPARQLPREFIX
			LANG
			LBRACE
			RBRACE
			EQUALS
			decrypt_constant
		)
	};
	use base 'Exporter';

	{
		my %mapping;
		my %reverse;
		BEGIN {
			my $cx	= 0;
			foreach my $name (grep { $_ ne 'decrypt_constant' } @EXPORT) {
				my $value	= ++$cx;
				$reverse{ $value }	= $name;
				$mapping{ $name }	= $value;
			}
		}
		use constant +{ %mapping };

=item C<< decrypt_constant ( $type ) >>

Returns the token name for the given token type.

=cut

		sub decrypt_constant { my $num	= +shift; $reverse{$num} }
	}
}

1;

__END__

=back

=head1 BUGS

Please report any bugs or feature requests to through the GitHub web interface
at L<https://github.com/kasei/perlrdf/issues>.

=head1 AUTHOR

Toby Inkster C<< <tobyink@cpan.org> >>

=head1 COPYRIGHT

Copyright (c) 2012 Toby Inkster. This
program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
