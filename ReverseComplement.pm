package ReverseComplement;
use strict;
use warnings;
use Exporter;
our $VERSION = 0.1;
#use vars qw($VERSION @ISA @EXPORT_OK );

our @ISA = qw(Exporter);
our @EXPORT_OK = qw(reverse_complement complement);

sub reverse_complement{
	my ($dna) = @_;
	$dna = reverse($dna);
	$dna = complement ($dna);
	return $dna;
	
}
sub complement{
	my ($dna) = @_;
	$dna =~ tr/acgtACGT/tgcaTGCA/;
	return $dna; 
}
1;

=head1 NAME

ReverseComplement.pm - reverse complement DNA strings

=head1 SYNOPSIS

use ReverseComplement qw (reverse_complement complement); 

$dna = "ATGCGATCGATGAC";

$revcomp = reverse_complement($dna);

$complement = complement($dna);


=head1 DESCRIPTION

A simple, lightweight module to perform a basic reverse complement function on DNA strings.  This module does not check any strings provided but simply reverses them and substitues the upper or lowercase characters 'A', 'C', 'G' and 'T' with their complement counterpart as defined by the standard base-pairing rules of DNA.  

=head1 AUTHOR

David A. Parry

=head1 COPYRIGHT AND LICENSE

Copyright 2016 David A. Parry

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with this program. If not, see <http://www.gnu.org/licenses/>.

=cut


