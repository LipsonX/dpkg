#
# Dpkg::Changelog
#
# Copyright © 2005, 2007 Frank Lichtenheld <frank@lichtenheld.de>
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA
#

=head1 NAME

Dpkg::Changelog

=head1 DESCRIPTION

to be written

=head2 Functions

=cut

package Dpkg::Changelog;

use strict;
use warnings;

use English;

use Dpkg;
use Dpkg::Gettext;
use Dpkg::ErrorHandling;

use base qw(Exporter);

our %EXPORT_TAGS = ( 'util' => [ qw(
                find_closes
                data2rfc822
                data2rfc822_mult
                get_dpkg_changes
) ] );
our @EXPORT_OK = @{$EXPORT_TAGS{util}};

=pod

=head3 init

Creates a new object instance. Takes a reference to a hash as
optional argument, which is interpreted as configuration options.
There are currently no supported general configuration options, but
see the other methods for more specific configuration options which
can also specified to C<init>.

If C<infile> or C<instring> are specified (see L<parse>), C<parse()>
is called from C<init>. If a fatal error is encountered during parsing
(e.g. the file can't be opened), C<init> will not return a
valid object but C<undef>!

=cut

sub init {
    my $classname = shift;
    my $config = shift || {};
    my $self = {};
    bless( $self, $classname );

    $config->{verbose} = 1 if $config->{debug};
    $self->{config} = $config;

    $self->reset_parse_errors;

    if ($self->{config}{infile} || $self->{config}{instring}) {
	defined($self->parse) or return undef;
    }

    return $self;
}

=pod

=head3 reset_parse_errors

Can be used to delete all information about errors ocurred during
previous L<parse> runs. Note that C<parse()> also calls this method.

=cut

sub reset_parse_errors {
    my ($self) = @_;

    $self->{errors}{parser} = [];
}

sub _do_parse_error {
    my ($self, $file, $line_nr, $error, $line) = @_;
    shift;

    push @{$self->{errors}{parser}}, [ @_ ];

    unless ($self->{config}{quiet}) {
	if ($line) {
	    warning("%20s(l$NR): $error\nLINE: $line", $file);
	} else {
	    warning("%20s(l$NR): $error", $file);
	}
    }
}

=pod

=head3 get_parse_errors

Returns all error messages from the last L<parse> run.
If called in scalar context returns a human readable
string representation. If called in list context returns
an array of arrays. Each of these arrays contains

=over 4

=item 1.

the filename of the parsed file or C<String> if a string was
parsed directly

=item 2.

the line number where the error occurred

=item 3.

an error description

=item 4.

the original line

=back

NOTE: This format isn't stable yet and may change in later versions
of this module.

=cut

sub get_parse_errors {
    my ($self) = @_;

    if (wantarray) {
	return @{$self->{errors}{parser}};
    } else {
	my $res = "";
	foreach my $e (@{$self->{errors}{parser}}) {
	    if ($e->[3]) {
		$res .= warning(_g("%s(l%s): %s\nLINE: %s"), @$e );
	    } else {
		$res .= warning(_g("%s(l%s): %s"), @$e );
	    }
	}
	return $res;
    }
}

sub _do_fatal_error {
    my ($self, @msg) = @_;

    $self->{errors}{fatal} = "@msg";
    warning(_g("FATAL: %s"), "@msg")."\n" unless $self->{config}{quiet};
}

=pod

=head3 get_error

Get the last non-parser error (e.g. the file to parse couldn't be opened).

=cut

sub get_error {
    my ($self) = @_;

    return $self->{errors}{fatal};
}

=pod

=head3 data

C<data> returns an array (if called in list context) or a reference
to an array of Dpkg::Changelog::Entry objects which each
represent one entry of the changelog.

This method supports the common output options described in
section L<"COMMON OUTPUT OPTIONS">.

=cut

sub data {
    my ($self, $config) = @_;

    my $data = $self->{data};
    if ($config) {
	$self->{config}{DATA} = $config if $config;
	$data = $self->_data_range( $config ) or return undef;
    }
    return @$data if wantarray;
    return $data;
}

sub __sanity_check_range {
    my ( $data, $from, $to, $since, $until, $start, $end ) = @_;

    if (($$start || $$end) && ($$from || $$since || $$to || $$until)) {
	warning(_g( "you can't combine 'count' or 'offset' with any other range option" ));
	$$from = $$since = $$to = $$until = '';
    }
    if ($$from && $$since) {
	warning(_g( "you can only specify one of 'from' and 'since'" ));
	$$from = '';
    }
    if ($$to && $$until) {
	warning(_g( "you can only specify one of 'to' and 'until'" ));
	$$to = '';
    }
    if ($$since && ($data->[0]{Version} eq $$since)) {
	warning(_g( "'since' option specifies most recent version" ));
	$$since = '';
    }
    if ($$until && ($data->[$#{$data}]{Version} eq $$until)) {
	warning(_g( "'until' option specifies oldest version" ));
	$$until = '';
    }
    $$start = 0 if $$start < 0;
    return if $$start > $#$data;
    $$end = $#$data if $$end > $#$data;
    return if $$end < 0;
    $$end = $$start if $$end < $$start;
    #TODO: compare versions
    return 1;
}

sub _data_range {
    my ($self, $config) = @_;

    my $data = $self->data or return undef;

    return [ @$data ] if $config->{all};

    my $since = $config->{since} || '';
    my $until = $config->{until} || '';
    my $from = $config->{from} || '';
    my $to = $config->{to} || '';
    my $count = $config->{count} || 0;
    my $offset = $config->{offset} || 0;

    return if $offset and not $count;
    if ($offset > 0) {
	$offset -= ($count < 0);
    } elsif ($offset < 0) {
	$offset = $#$data + ($count > 0) + $offset;
    } else {
	$offset = $#$data if $count < 0;
    }
    my $start = my $end = $offset;
    $start += $count+1 if $count < 0;
    $end += $count-1 if $count > 0;

    return unless __sanity_check_range( $data, \$from, \$to,
					\$since, \$until,
					\$start, \$end );


    unless ($from or $to or $since or $until or $start or $end) {
	return [ @$data ] if $config->{default_all} and not $count;
	return [ $data->[0] ];
    }

    return [ @{$data}[$start .. $end] ] if $start or $end;

    my @result;

    my $include = 1;
    $include = 0 if $to or $until;
    foreach (@$data) {
	my $v = $_->{Version};
	$include = 1 if $v eq $to;
	last if $v eq $since;

	push @result, $_ if $include;

	$include = 1 if $v eq $until;
	last if $v eq $from;
    }

    return \@result;
}

=pod

=head3 dpkg

(and B<dpkg_str>)

C<dpkg> returns a hash (in list context) or a hash reference
(in scalar context) where the keys are field names and the values are
field values. The following fields are given:

=over 4

=item Source

package name (in the first entry)

=item Version

packages' version (from first entry)

=item Distribution

target distribution (from first entry)

=item Urgency

urgency (highest of all printed entries)

=item Maintainer

person that created the (first) entry

=item Date

date of the (first) entry

=item Closes

bugs closed by the entry/entries, sorted by bug number

=item Changes

content of the the entry/entries

=back

C<dpkg_str> returns a stringified version of this hash. The fields are
ordered like in the list above.

Both methods support the common output options described in
section L<"COMMON OUTPUT OPTIONS">.

=head3 dpkg_str

See L<dpkg>.

=cut

our ( %FIELDIMPS, %URGENCIES );
BEGIN {
    my $i=100;
    grep($FIELDIMPS{$_}=$i--,
	 qw(Source Version Distribution Urgency Maintainer Date Closes
	    Changes));
    $i=1;
    grep($URGENCIES{$_}=$i++,
	 qw(low medium high critical emergency));
}

sub dpkg {
    my ($self, $config) = @_;

    $self->{config}{DPKG} = $config if $config;

    $config = $self->{config}{DPKG} || {};
    my $data = $self->_data_range( $config ) or return undef;

    my %f;
    foreach my $field (qw( Urgency Source Version
			   Distribution Maintainer Date )) {
	$f{$field} = $data->[0]{$field};
    }

    $f{Changes} = get_dpkg_changes( $data->[0] );
    $f{Closes} = [ @{$data->[0]{Closes}} ];

    my $first = 1; my $urg_comment = '';
    foreach my $entry (@$data) {
	$first = 0, next if $first;

	my $oldurg = $f{Urgency} || '';
	my $oldurgn = $URGENCIES{$f{Urgency}} || -1;
	my $newurg = $entry->{Urgency_LC} || '';
	my $newurgn = $URGENCIES{$entry->{Urgency_LC}} || -1;
	$f{Urgency} = ($newurgn > $oldurgn) ? $newurg : $oldurg;
	$urg_comment .= $entry->{Urgency_Comment};

	$f{Changes} .= "\n .".get_dpkg_changes( $entry );
	push @{$f{Closes}}, @{$entry->{Closes}};
    }

    $f{Closes} = join " ", sort { $a <=> $b } @{$f{Closes}};
    $f{Urgency} .= $urg_comment;

    return %f if wantarray;
    return \%f;
}

sub dpkg_str {
    return data2rfc822( scalar dpkg(@_), \%FIELDIMPS );
}

=pod

=head3 rfc822

(and B<rfc822_str>)

C<rfc822> returns an array of hashes (in list context) or a reference
to this array (in scalar context) where each hash represents one entry
in the changelog. For the format of such a hash see the description
of the L<"dpkg"> method (while ignoring the remarks about which
values are taken from the first entry).

C<rfc822_str> returns a stringified version of this array.

Both methods support the common output options described in
section L<"COMMON OUTPUT OPTIONS">.

=head3 rfc822_str

See L<rfc822>.

=cut

sub rfc822 {
    my ($self, $config) = @_;

    $self->{config}{RFC822} = $config if $config;

    $config = $self->{config}{RFC822} || {};
    my $data = $self->_data_range( $config ) or return undef;
    my @out_data;

    foreach my $entry (@$data) {
	my %f;
	foreach my $field (qw( Urgency Source Version
			   Distribution Maintainer Date )) {
	    $f{$field} = $entry->{$field};
	}

	$f{Urgency} .= $entry->{Urgency_Comment};
	$f{Changes} = get_dpkg_changes( $entry );
	$f{Closes} = join " ", sort { $a <=> $b } @{$entry->{Closes}};
	push @out_data, \%f;
    }

    return @out_data if wantarray;
    return \@out_data;
}

sub rfc822_str {
    return data2rfc822_mult( scalar rfc822(@_), \%FIELDIMPS );
}

=pod

=head1 COMMON OUTPUT OPTIONS

The following options are supported by all output methods,
all take a version number as value:

=over 4

=item since

Causes changelog information from all versions strictly
later than B<version> to be used.

=item until

Causes changelog information from all versions strictly
earlier than B<version> to be used.

=item from

Similar to C<since> but also includes the information for the
specified B<version> itself.

=item to

Similar to C<until> but also includes the information for the
specified B<version> itself.

=back

The following options also supported by all output methods but
don't take version numbers as values:

=over 4

=item all

If set to a true value, all entries of the changelog are returned,
this overrides all other options.

=item count

Expects a signed integer as value. Returns C<value> entries from the
top of the changelog if set to a positive integer, and C<abs(value)>
entries from the tail if set to a negative integer.

=item offset

Expects a signed integer as value. Changes the starting point for
C<count>, either counted from the top (positive integer) or from
the tail (negative integer). C<offset> has no effect if C<count>
wasn't given as well.

=back

Some examples for the above options. Imagine an example changelog with
entries for the versions 1.2, 1.3, 2.0, 2.1, 2.2, 3.0 and 3.1.

            Call                               Included entries
 C<E<lt>formatE<gt>({ since =E<gt> '2.0' })>  3.1, 3.0, 2.2
 C<E<lt>formatE<gt>({ until =E<gt> '2.0' })>  1.3, 1.2
 C<E<lt>formatE<gt>({ from =E<gt> '2.0' })>   3.1, 3.0, 2.2, 2.1, 2.0
 C<E<lt>formatE<gt>({ to =E<gt> '2.0' })>     2.0, 1.3, 1.2
 C<E<lt>formatE<gt>({ count =E<gt> 2 }>>      3.1, 3.0
 C<E<lt>formatE<gt>({ count =E<gt> -2 }>>     1.3, 1.2
 C<E<lt>formatE<gt>({ count =E<gt> 3,
		      offset=E<gt> 2 }>>      2.2, 2.1, 2.0
 C<E<lt>formatE<gt>({ count =E<gt> 2,
		      offset=E<gt> -3 }>>     2.0, 1.3
 C<E<lt>formatE<gt>({ count =E<gt> -2,
		      offset=E<gt> 3 }>>      3.0, 2.2
 C<E<lt>formatE<gt>({ count =E<gt> -2,
		      offset=E<gt> -3 }>>     2.2, 2.1

Any combination of one option of C<since> and C<from> and one of
C<until> and C<to> returns the intersection of the two results
with only one of the options specified.

=head1 UTILITY FUNCTIONS

=head3 find_closes

Takes one string as argument and finds "Closes: #123456, #654321" statements
as supported by the Debian Archive software in it. Returns all closed bug
numbers in an array reference.

=cut

sub find_closes {
    my $changes = shift;
    my @closes = ();

    while ($changes &&
	   ($changes =~ /closes:\s*(?:bug)?\#?\s?\d+(?:,\s*(?:bug)?\#?\s?\d+)*/ig)) {
	push(@closes, $& =~ /\#?\s?(\d+)/g);
    }

    @closes = sort { $a <=> $b } @closes;
    return \@closes;
}

=pod

=head3 data2rfc822

Takes two hash references as arguments. The first should contain the
data to output in RFC822 format. The second can contain a sorting order
for the fields. The higher the numerical value of the hash value, the
earlier the field is printed if it exists.

Return the data in RFC822 format as string.

=cut

sub data2rfc822 {
    my ($data, $fieldimps) = @_;
    my $rfc822_str = '';

# based on /usr/lib/dpkg/controllib.pl
    for my $f (sort { $fieldimps->{$b} <=> $fieldimps->{$a} } keys %$data) {
	my $v= $data->{$f} or next;
	$v =~ m/\S/o || next; # delete whitespace-only fields
	$v =~ m/\n\S/o
	    && warning(_g("field %s has newline then non whitespace >%s<",
			  $f, $v ));
	$v =~ m/\n[ \t]*\n/o && warning(_g("field %s has blank lines >%s<",
					   $f, $v ));
	$v =~ m/\n$/o && warning(_g("field %s has trailing newline >%s<",
				    $f, $v ));
	$v =~ s/\$\{\}/\$/go;
	$rfc822_str .= "$f: $v\n";
    }

    return $rfc822_str;
}

=pod

=head3 data2rfc822_mult

The first argument should be an array ref to an array of hash references.
The second argument is a hash reference and has the same meaning as
the second argument of L<data2rfc822>.

Calls L<data2rfc822> for each element of the array given as first
argument and returns the concatenated results.

=cut

sub data2rfc822_mult {
    my ($data, $fieldimps) = @_;
    my @rfc822 = ();

    foreach my $entry (@$data) {
	push @rfc822, data2rfc822($entry,$fieldimps);
    }

    return join "\n", @rfc822;
}

=pod

=head3 get_dpkg_changes

Takes a Dpkg::Changelog::Entry object as first argument.

Returns a string that is suitable for using it in a C<Changes> field
in the output format of C<dpkg-parsechangelog>.

=cut

sub get_dpkg_changes {
    my $changes = "\n ".($_[0]->Header||'')."\n .\n".($_[0]->Changes||'');
    chomp $changes;
    $changes =~ s/^ $/ ./mgo;
    return $changes;
}

=head1 NAME

Dpkg::Changelog::Entry - represents one entry in a Debian changelog

=head1 SYNOPSIS

=head1 DESCRIPTION

=head2 Methods

=head3 init

Creates a new object, no options.

=head3 new

Alias for init.

=head3 is_empty

Checks if the object is actually initialized with data. This
currently simply checks if one of the fields Source, Version,
Maintainer, Date, or Changes is initalized.

=head2 Accessors

The following fields are available via accessor functions (all
fields are string values unless otherwise noted):

=over 4

=item *

Source

=item *

Version

=item *

Distribution

=item *

Urgency

=item *

ExtraFields (all fields except for urgency as hash)

=item *

Header (the whole header in verbatim form)

=item *

Changes (the actual content of the bug report, in verbatim form)

=item *

Trailer (the whole trailer in verbatim form)

=item *

Closes (Array of bug numbers)

=item *

Maintainer (name B<and> email address)

=item *

Date

=item *

Timestamp (Date expressed in seconds since the epoche)

=item *

ERROR (last parse error related to this entry in the format described
at Dpkg::Changelog::get_parse_errors.

=back

=cut

package Dpkg::Changelog::Entry;

use base qw( Class::Accessor );

Dpkg::Changelog::Entry->mk_accessors(qw( Closes Changes Maintainer
					 MaintainerEmail Date
					 Urgency Distribution
					 Source Version ERROR
					 ExtraFields Header
					 Trailer Timestamp ));

sub new {
    return init(@_);
}

sub init {
    my $classname = shift;
    my $self = {};
    bless( $self, $classname );

    return $self;
}

sub is_empty {
    my ($self) = @_;

    return !($self->{Changes}
	     || $self->{Source}
	     || $self->{Version}
	     || $self->{Maintainer}
	     || $self->{Date});
}

1;
__END__

=head1 AUTHOR

Frank Lichtenheld, E<lt>frank@lichtenheld.deE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright E<copy> 2005, 2007 by Frank Lichtenheld

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA

=cut
