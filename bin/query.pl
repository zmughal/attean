#!/usr/bin/env perl

use v5.20;
use warnings;
no warnings 'once';
use autodie;
use File::Slurp;
use Scalar::Util qw(blessed);
use Attean;
use Attean::RDF;
use Attean::SimpleQueryEvaluator;
use RDF::Query;
use Data::Dumper;
use Getopt::Long;
use Try::Tiny;
use Benchmark qw(timethese);

BEGIN { $Error::TypeTiny::StackTrace	= 1; }

package Translator 0.1 {
	use v5.20;
	use warnings;
	use Moo;
	use Data::Dumper;
	use namespace::clean;
	
	use Attean::RDF;
	use Scalar::Util qw(blessed);
	use Types::Standard qw(Bool);
	has 'in_expr' => (is => 'rw', isa => Bool, default => 0);
	
	sub translate {
		my $self	= shift;
		my $a		= shift;
		die "Not a reference? " . Dumper($a) unless blessed($a);
		if ($a->isa('RDF::Query::Algebra::Project')) {
			my $p	= $a->pattern;
			my $v	= $a->vars;
			my @vars	= map { variable($_->name) } @$v;
			return Attean::Algebra::Project->new(
				children	=> [ $self->translate($p) ],
				variables	=> [ @vars ],
			);
		} elsif ($a->isa('RDF::Query::Algebra::GroupGraphPattern')) {
			my @p	= map { $self->translate($_) } $a->patterns;
			if (scalar(@p) == 0) {
				return Attean::Algebra::BGP->new();
			} else {
				while (scalar(@p) > 1) {
					my ($l, $r)	= splice(@p, 0, 2);
					unshift(@p, Attean::Algebra::Join->new( children => [$l, $r] ));
				}
				return shift(@p);
			}
		} elsif ($a->isa('RDF::Query::Algebra::BasicGraphPattern')) {
			my @p	= map { $self->translate($_) } $a->triples;
			return Attean::Algebra::BGP->new( triples => \@p );
		} elsif ($a->isa('RDF::Query::Algebra::Triple')) {
			my @nodes	= map { $self->translate($_) } $a->nodes;
			return Attean::TriplePattern->new(@nodes);
		} elsif ($a->isa('RDF::Query::Node::Variable')) {
			my $value	= variable($a->isa("RDF::Query::Node::Variable::ExpressionProxy") ? ("." . $a->name) : $a->name);
			$value	= Attean::ValueExpression->new(value => $value) if ($self->in_expr);
			return $value;
		} elsif ($a->isa('RDF::Query::Node::Resource')) {
			my $value	= iri($a->uri_value);
			$value	= Attean::ValueExpression->new(value => $value) if ($self->in_expr);
			return $value;
		} elsif ($a->isa('RDF::Query::Node::Blank')) {
			my $value	= blank($a->blank_identifier);
			$value	= Attean::ValueExpression->new(value => $value) if ($self->in_expr);
			return $value;
		} elsif ($a->isa('RDF::Query::Node::Literal')) {
			my $value;
			if ($a->has_language) {
				$value	= langliteral($a->literal_value, $a->literal_value_language);
			} elsif ($a->has_datatype) {
				$value	= dtliteral($a->literal_value, $a->literal_datatype);
			} else {
				$value	= literal($a->literal_value);
			}
			$value	= Attean::ValueExpression->new(value => $value) if ($self->in_expr);
			return $value;
		} elsif ($a->isa('RDF::Query::Algebra::Limit')) {
			my $child	= $a->pattern;
			if ($child->isa('RDF::Query::Algebra::Offset')) {
				my $p	= $self->translate($child->pattern);
				return Attean::Algebra::Slice->new( children => [$p], limit => $a->limit, offset => $child->offset );
			} else {
				my $p	= $self->translate($child);
				return Attean::Algebra::Slice->new( children => [$p], limit => $a->limit );
			}
		} elsif ($a->isa('RDF::Query::Algebra::Offset')) {
			my $p	= $self->translate($a->pattern);
			return Attean::Algebra::Slice->new( children => [$p], offset => $a->offset );
		} elsif ($a->isa('RDF::Query::Algebra::Path')) {
			my $s		= $self->translate($a->start);
			my $o		= $self->translate($a->end);
			my $path	= $self->translate_path($a->path);
			return Attean::Algebra::Path->new( subject => $s, path => $path, object => $o );
		} elsif ($a->isa('RDF::Query::Algebra::NamedGraph')) {
			my $graph	= $self->translate($a->graph);
			my $p		= $self->translate($a->pattern);
			return Attean::Algebra::Graph->new( children => [$p], graph => $graph );
		} elsif ($a->isa('RDF::Query::Algebra::Filter')) {
			my $p		= $self->translate($a->pattern);
			my $expr	= $self->translate_expr($a->expr);
			return Attean::Algebra::Filter->new( children => [$p], expression => $expr );
		} elsif ($a->isa('RDF::Query::Expression::Binary')) {
			my $op	= $a->op;
			$op		= '=' if ($op eq '==');
			my @ops	= $a->operands;
			my @operands	= map { $self->translate($_) } @ops;
			my $expr	= Attean::BinaryExpression->new( operator => $op, children => \@operands );
			return $expr;
		} elsif ($a->isa('RDF::Query::Algebra::Extend')) {
			my $p		= $self->translate($a->pattern);
			my $vars	= $a->vars;
			foreach my $v (@$vars) {
				if ($v->isa('RDF::Query::Expression::Alias')) {
					my $var		= variable($v->name);
					my $expr	= $v->expression;
					$p	= Attean::Algebra::Extend->new( children => [$p], variable => $var, expression => $self->translate_expr( $expr ) );
				} else {
					die "Unexpected extend expression: " . Dumper($v);
				}
			}
			return $p;
		} elsif ($a->isa('RDF::Query::Algebra::Aggregate')) {
			my $p		= $self->translate($a->pattern);
			my @group	= map { $self->translate_expr($_) } $a->groupby;
			my @ops		= $a->ops;
			
			my @aggs;
			foreach my $o (@ops) {
				my ($str, $op, $scalar_vars, @vars)	= @$o;
				my $operands	= [map { $self->translate_expr($_) } grep { blessed($_) } @vars];
				my $expr	= Attean::AggregateExpression->new(
					operator => $op,
					children => $operands,
					scalar_vars => $scalar_vars,
					variable => variable(".$str"),
				);
				push(@aggs, $expr);
			}
			return Attean::Algebra::Group->new(
				children	=> [$p],
				groupby		=> \@group,
				aggregates	=> \@aggs,
			);
		} elsif ($a->isa('RDF::Query::Expression::Function')) {
			my $uri		= $a->uri->uri_value;
			my @args	= map { $self->translate_expr($_) } $a->arguments;
			if ($uri =~ /^sparql:(.+)$/) {
				return Attean::FunctionExpression->new( children => \@args, operator => $1 );
			}
			warn Dumper($uri, \@args);
		}
		die "Unrecognized algebra " . ref($a);
	}

	sub translate_expr {
		my $self	= shift;
		my $a		= shift;
		my $prev	= $self->in_expr;
		$self->in_expr(1);
		my $expr	= $self->translate($a);
		$self->in_expr($prev);
		return $expr;
	}
	
	sub translate_path {
		my $self	= shift;
		my $path	= shift;
		if (blessed($path) and $path->isa('RDF::Query::Node::Resource')) {
			return Attean::Algebra::PredicatePath->new( predicate => $self->translate($path) );
		}
		
		my ($op, @args)	= @$path;
		if ($op eq '!') {
			my @nodes	= map { $self->translate($_) } @args;
			return Attean::Algebra::NegatedPropertySet->new( predicates => \@nodes );
		} elsif ($op eq '/') {
			my @paths	= map { $self->translate_path($_) } @args;
			foreach (@paths) {
				if ($_->does('Attean::API::IRI')) {
					$_	= Attean::Algebra::PredicatePath->new( predicate => $_ );
				}
			}
			return Attean::Algebra::SequencePath->new( children => \@paths );
		} elsif ($op eq '^') {
			my $path	= $self->translate(shift(@args));
			if ($path->does('Attean::API::IRI')) {
				$path	= Attean::Algebra::PredicatePath->new( predicate => $path );
			}
			return Attean::Algebra::InversePath->new( children => [$path] );
		} elsif ($op eq '|') {
			my @paths	= map { $self->translate($_) } @args;
			foreach (@paths) {
				if ($_->does('Attean::API::IRI')) {
					$_	= Attean::Algebra::PredicatePath->new( predicate => $_ );
				}
			}
			return Attean::Algebra::AlternativePath->new( children => \@paths );
		}
		die "Unrecognized path: $op";
	}
}


if (scalar(@ARGV) < 2) {
	print STDERR <<"END";
Usage: $0 data.ttl query.rq

Uses RDF::Query to parse the supplied SPARQL query, translates the parsed query
form to an Attean::Algebra object, and executes it against a model containing
the RDF data parsed from the data file using Attean::SimpleQueryEvaluator.

END
	exit;
}

my $verbose	= 0;
my $debug	= 0;
my $benchmark	= 0;
my $result	= GetOptions ("verbose" => \$verbose, "debug" => \$debug, "benchmark" => \$benchmark);

my $data	= shift;
my $qfile	= shift;

open(my $fh, '<:encoding(UTF-8)', $data);

try {
	warn "Constructing model...\n" if ($verbose);
	my $store	= Attean->get_store('Memory')->new();
	my $model	= Attean::MutableQuadModel->new( store => $store );
	my $graph	= Attean::IRI->new('http://example.org/graph');

	{
		warn "Parsing data...\n" if ($verbose);
		my $parser	= Attean->get_parser('Turtle')->new();
		my $iter	= $parser->parse_iter_from_io($fh);
		my $quads	= $iter->as_quads($graph);
		$store->add_iter($quads);
	}

	if ($debug) {
		my $iter	= $model->get_quads();
		while (my $q = $iter->next) {
			say $q->as_string;
		}
	}

	warn "Parsing query...\n" if ($verbose);
	my $sparql	= read_file($qfile);
	my $query	= RDF::Query->new($sparql);
	unless ($query) {
		die RDF::Query->error;
	}
	my $p		= $query->pattern;

	warn "Translating query...\n" if ($verbose);
	my $t	= Translator->new();
	my $a		= $t->translate($p);
	if ($debug) {
		warn "Walking algebra:\n";
		$a->walk( prefix => sub { my $a = shift; warn "- $a\n" });
	}
	
	if ($debug) {
		warn Dumper($a);
	}

	warn "Evaluating query...\n" if ($verbose);
	my $e		= Attean::SimpleQueryEvaluator->new( model => $model, default_graph => $graph );
	if ($benchmark) {
		timethese(5, {
			'baseline'	=> sub { local($ENV{ATTEAN_NO_MERGE_JOIN}) = 1; my @e = $e->evaluate($a, $graph)->elements },
			'mergejoin'	=> sub { my @e = $e->evaluate($a, $graph)->elements },
		});
	} else {
		my $iter	= $e->evaluate($a, $graph);
		my $count	= 1;
		while (my $r = $iter->next) {
			printf("%3d %s\n", $count++, $r->as_string);
		}
	}
} catch {
	my $exception	= $_;
	warn "Caught error: $exception";
	warn $exception->stack_trace;
};
