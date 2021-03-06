=head1 NAME

VcfReader.pm - parse VCF headers, lines and search VCFs

=head1 VERSION

version 0.3

=head1 SYNOPSIS

 use VcfReader;
 
 my $vcf = 'example.vcf'; 
 #Check header is OK
 die "Header not ok for input ($vcf) "  if not VcfReader::checkHeader( vcf => $vcf );

 #search header lines for contigs
 my @head = VcfReader::getHeader($vcf);
 my @contigs = grep {/##contig=</} @head;

 #print header
 my $head_string = VcfReader::getHeader($vcf);
 print $head_string;

 #get sample names
 my @samples = VcfReader::getSamples(vcf => $vcf);
 
 #get a hash of sample names to column numbers 
 my %samples_to_columns = VcfReader::getSamples(vcf => $vcf, get_columns => 1);

 #parse lines of a VCF
 open (my $VCF, $vcf) or die "$!\n";
 while (<$VCF>){
     next if /^#/;
     chomp;
     my @line = split(/\t/); #VcfReader functions require split lines
     
     #very unsophisticated SNP filter
     my $id = VcfReader::getVariantField(\@line, 'ID');
     next if $id =~ /rs\d+/; 
     
     #basic allele frequency filter
     my $af = VcfReader::getVariantInfoField(\@line, 'AF');
     foreach my $freq (split(",", $af)){
         if ($af < 0.1){
             print; 
         }
     }

     #get genotype data for sample 'FOO' 
     my $sample_variant = VcfReader::getSampleVariant(\@line, $samples_to_columns{'FOO'});

     #get genotype quality genotype field for sample 'FOO'
     my $gq = VcfReader::getSampleGenotypeField
     (
         line => \@line, 
         field => "GQ",
         sample => "FOO", 
         sample_to_columns => \%samples_to_columns
     );
     
     #get sample call for sample 'FOO' but return no call ("./.") if genotype quality is less than 20
     my $gt = VcfReader::getSampleCall
     (
         line => \@line, 
         sample => "FOO", 
         minGQ => 20,
         sample_to_columns => \%samples_to_columns
     );

     #print sample calls for sample 'FOO' and sample 'BAR'
     my %samp_to_gt = VcfReader::getSampleCall
     (
         line => \@line, 
         multiple => ["FOO", "BAR"],
         sample_to_columns => \%samples_to_columns
     );
     print "Sample FOO has genotype $samp_to_gt{FOO}\n";
     print "Sample BAR has genotype $samp_to_gt{BAR}\n";
 }
 close $VCF;

 #sort a VCF 
 VcfReader::sortVcf(vcf => 'unsorted_file.vcf' output => 'sorted_file.vcf');

 #search VCF by region and print results
 my %search_arguments = VcfReader::getSearchArguments('file.vcf');
 my @hits = VcfReader::searchByRegion
 (
     %search_arguments,
     chrom => '1',
     start => 1000000,
     end   => 2000000,
 );
 print join("\n", @hits);

 #compare two lines for matching variants
 my %min_var1 = VcfReader::minimizeAlleles(\@line1);
 my %min_var2 = VcfReader::minimizeAlleles(\@line2);
 foreach my $allele1 (keys %min_var1){
     foreach my $allele2 (keys %min_var2){
         next if $min_var1{$allele1}->{CHROM} ne $min_var2{$allele2}->{CHROM};
         next if $min_var1{$allele1}->{POS}   ne $min_var2{$allele2}->{POS};
         next if $min_var1{$allele1}->{REF}   ne $min_var2{$allele2}->{REF};
         next if $min_var1{$allele1}->{ALT}   ne $min_var2{$allele2}->{ALT};
         print "line1 allele $allele1 matches line2 $allele2!\n";
     }
 }
 

=cut

package VcfReader;
use strict;
use warnings;
use Carp;
use IO::Uncompress::Gunzip qw/ gunzip $GunzipError /;
use IO::Compress::Gzip qw/ gzip $GzipError / ;
use Fcntl 'SEEK_SET';
use Data::Dumper;
use List::Util qw / sum /;
use File::Temp qw/ tempfile /;
use File::Copy;
use Scalar::Util qw/ openhandle /;
#require Exporter;
#our @ISA = qw(Exporter);
#our @EXPORT_OK = qw();
our $VERSION = 0.3;
use constant VCF_FIELDS => 
{
    CHROM   => 0, 
    POS     => 1,
    ID      => 2,
    REF     => 3,
    ALT     => 4, 
    QUAL    => 5, 
    FILTER  => 6, 
    INFO    => 7, 
    FORMAT  => 8,
};

#index every 0-99999 bp of a chrom
my $REGION_SPANS = 100000;
my $getUncompressFilehandle;#sub defined depending on available tools/modules
BEGIN{
    #define our subroutine for handling bgzip compressed VCFs
    #note, that PerlIO::gzip does not handle block compressed data, 
    #stopping at the end of the first block, so our methods in order of speed
    # are: 
    #         native gzip > Compress::BGZF::Reader > IO::Uncompress::Gunzip
    #
    my $gzip = `which gzip`;
    chomp $gzip;
    if ($gzip and -x $gzip){
    #fastest decomp method uses native gunzip
        $getUncompressFilehandle = sub {
            my $f = shift;
            open (my $FH, "gzip -dc $f |") or croak "Error opening $f via gzip: $! ";
            return $FH;
        }
    }elsif(eval "use Compress::BGZF::Reader; 1" ){
    # Compress::BGZF::Reader is actually faster than IO::Uncompress::Gunzip
    # in multistream mode
        $getUncompressFilehandle = sub {
            my $f = shift;
            my $FH = Compress::BGZF::Reader->new_filehandle( $f )  or 
                croak "Compress::BGZF::Reader failed while opening $f for ".
                "reading:\n$!";
            return $FH;
        };
    }else{
    # IO::Uncompress::Gunzip should be in core perl
        $getUncompressFilehandle = sub {
            my $f = shift;
            my $FH = new IO::Uncompress::Gunzip $f, MultiStream => 1 or 
              croak "IO::Uncompress::Gunzip failed while opening $f for ".
              "reading:\n$GunzipError";
            return $FH;
        };
    }
}

=head1 FUNCTIONS


=head2 Header Utilities

=over 12

=item B<getHeader>

Retrieve the whole header from a VCF file including meta header lines.  Returns an array if called in an array context and a string if not. Takes a VCF file or filehandle as an argument. If a filehandle is provided seek will be used to position back to the first non-header line (this will NOT work for STDIN or pipes, you will lose the first non-header line if used with non-seekable filehandles like these).

 my @head_lines = VcfReader::getHeader("file.vcf");
 
 my @head_lines = VcfReader::getHeader($FH);

=cut
sub getHeader{
    my $vcf = shift; 
    croak "getHeader method requires a file as an argument" if not $vcf;
    my $FH;
    my $is_fh = 0;
    if (fileno($vcf)){
        $FH = $vcf;
        $is_fh = 1;
    }else{
        $FH = _openFileHandle($vcf);
    }
    my @header = ();
    my $offset = tell($FH); 
    while (my $vcf_line = scalar readline $FH){
        if ($vcf_line =~ /^#/){
            chomp $vcf_line;
            push(@header, $vcf_line);
            my $offset = tell($FH); 
        }else{
            croak "No header found for VCF file $vcf " if not @header;
            last;
        }
    }
    if ($is_fh){
        seek($FH, $offset, 0);#if user provided a FH, return to first non-header line
    }else{
        close $FH;
    }
    croak "No header found for VCF file $vcf " if not @header;
    return @header if wantarray;
    return join("\n", @header) ."\n" if defined wantarray;
    carp "getHeader called in void context ";
}

=item B<getMetaHeader>

Retrieve the meta header lines from a VCF file.  Returns an array if called in an array context and a string if not. 

 my @head_lines = VcfReader::getMetaHeader("file.vcf");

=cut

sub getMetaHeader{
    my $vcf = shift; 
    croak "printMetaHeader method requires a file as an argument" if not $vcf;
    my @header = grep {/^##/} getHeader($vcf);
    return @header if wantarray;
    return join("\n", @header) if defined wantarray;
    carp "getMetaHeader called in void context ";
}

=item B<getColumnHeader>

Retrieve the column header line from a VCF file. Returns a string without newline.

 my $column_header = VcfReader::getColumnHeader("file.vcf");

=cut

sub getColumnHeader{
    my $vcf = shift; 
    croak "printColumnHeader method requires a file as an argument" if not $vcf;
    my @header = grep {/^#CHROM/} getHeader($vcf);
    if (@header < 1){
        croak "No column header found for $vcf ";
    }
    if (@header > 1){
        carp "Warning - more than 1 column header found for $vcf ";
    }
    return "$header[-1]";
}

=item B<getHeaderAndFilehandle>

Retrieve the whole header from a VCF file including meta header lines from a given file/filehandle. Returns a ref to an array of header lines and the filehandle, which is positioned to read the first non-header line. Because this method uses seek to return to the first non-header line, it should NOT be used with data from STDIN or pipes. If you use this with STDIN or pipes the first non-header line will be skipped without warning - instead use the getHeaderAndFirstVariant method below.
 
 my ($head_lines, $FH) = VcfReader::getHeaderFromFilehandle("file.vcf");

 my ($head_lines, $FH) = VcfReader::getHeaderFromFilehandle($FH);
 

=cut
sub getHeaderAndFilehandle{
    my $vcf = shift; 
    croak "getHeader method requires a file or filehandle as an argument" if not $vcf;
    my $FH;
    if (fileno($vcf)){
        $FH = $vcf;
    }else{
        $FH = _openFileHandle($vcf);
    }
    my @header = ();
    my $offset = tell($FH); 
    while (my $vcf_line = scalar readline $FH){
        if ($vcf_line =~ /^#/){
            chomp $vcf_line;
            push(@header, $vcf_line);
            $offset = tell($FH);
        }else{
            croak "No header found for VCF file " if not @header;
            last;
        }
    }
    seek($FH, $offset, 0);
    croak "No header found for VCF file " if not @header;
    return (\@header, $FH) if defined wantarray;
    carp "getHeader called in void context ";
}

=item B<getHeaderAndFirstVariant>

Retrieve the whole header from a VCF file including meta header lines from a given file/filehandle. Returns a ref to an array of header lines, the first variant and the filehandle, which will be positioned to read the second line after the header. The idea being that this allows you to work with data from STDIN, giving you the header, the first non-header line for processing and a filehandled positioned to allow you to process remaining lines. 
 
 my ($head_lines, $first, $FH) = VcfReader::getHeaderAndFirstVariant("file.vcf");

 my ($head_lines, $first, $FH) = VcfReader::getHeaderAndFirstVariant($FH);
 

=cut

sub getHeaderAndFirstVariant{
    my $vcf = shift; 
    croak "getHeader method requires a file or filehandle as an argument" if not $vcf;
    my $FH;
    if (fileno($vcf)){
        $FH = $vcf;
    }else{
        $FH = _openFileHandle($vcf);
    }
    my @header = ();
    my $first_var = '';
    while (my $vcf_line = scalar readline $FH){
        chomp $vcf_line;
        if ($vcf_line =~ /^#/){
            push(@header, $vcf_line);
        }else{
            croak "No header found for VCF file " if not @header;
            $first_var = $vcf_line;
            last;
        }
    }
    croak "No header found for VCF file " if not @header;
    return (\@header, $first_var, $FH) if defined wantarray;
    carp "getHeader called in void context ";
}




=item B<checkHeader>

Checks the column header of a VCF file for the mandatory columns. Returns 1 if the header is OK and 0 if not.

Arguments

=over 16

=item vcf

filename of VCF file to check.

=item header

Header string or an array of header lines in the same order they appear in a file. Ignored if using 'vcf' argument.

=back

 die "Bad header!\n" if (not VcfReader::checkHeader(vcf => "file.vcf");

=cut

sub checkHeader{
    #returns 1 if header ok
    #returns 0 if not
    my (%args) = @_;
    my @header = ();
    if ($args{vcf}){
        @header = getHeader($args{vcf});
    }elsif($args{header}){
        if (ref $args{header} eq 'ARRAY'){
            @header = @{$args{header}};
        }else{
            @header = split("\n", $args{header});
        }
    }else{
        croak "readHeader method requires either 'vcf' or 'header arguments ";
    }
    if ($header[-1] !~ /^#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO(\tFORMAT)*/){
        return 0;
    }else{
        return 1;
    }
}

=item B<getHeaderColumns>

Returns and array of the column names in the order they appear in the VCF. Requires either "vcf" or "header" argument. The former requires a filename while the "header" argument can be either a string or a reference to an array of header lines.

Arguments

=over 16

=item vcf

filename of VCF file to check.

=item header

Header string or a reference to an array of header lines in the same order they appear in a file. Ignored if using 'vcf' argument.

=back

 my @cols = VcfReader::getHeaderColumns(vcf => "file.vcf");

 my @cols = VcfReader::getHeaderColumns(header => \@header);

=cut

sub getHeaderColumns{
    my (%args) = @_;
    croak "Invalid header " if not checkHeader(%args);
    my @header = ();
    if ($args{vcf}){
        @header = getHeader($args{vcf});
    }elsif($args{header}){
        if (ref $args{header} eq 'ARRAY'){
            @header = @{$args{header}};
        }else{
            @header = split("\n", $args{header});
        }
    }else{
        croak "getHeaderColumns method requires either 'vcf' or 'header arguments ";
    }
    my @columns = split("\t", $header[-1]);
    return @columns;
}

=item B<getSamples>

Returns an array of sample names in the order they appear in the header or, if the "get_columns" argument is true, returns a hash of sample names to column numbers.  Requires either "vcf" or "header" argument. The former requires a filename while the "header" argument can be either a string or a reference to an array of header lines.

Arguments

=over 16

=item vcf

filename of VCF file to check.

=item header

Header string or an array of header lines in the same order they appear in a file. Ignored if using 'vcf' argument.

=item get_columns

If true this argument causes the function to return a hash of sample names to column numbers rather than an array of sample names.

=back

 die "Bad header!\n" if (not VcfReader::checkHeader(vcf => "file.vcf");
 my @samples = VcfReader::getSamples(vcf => "file.vcf");

 my %samples_to_columns = VcfReader::getSamples(vcf => "file.vcf", get_columns => 1);

=cut
sub getSamples{
#return either an array of sample names
#or a hash of sample_name => column number (if called with "get_columns => 1")
    my (%args) = @_;
    croak "Invalid header " if not checkHeader(%args);
    my @header = ();
    if ($args{vcf}){
        @header = getHeader($args{vcf});
    }elsif($args{header}){
        if (ref $args{header} eq 'ARRAY'){
            @header = @{$args{header}};
        }else{
            @header = split("\n", $args{header});
        }
    }else{
        croak "readHeader method requires either 'vcf' or 'header arguments ";
    }
    chomp @header;
    my @columns = split("\t", $header[-1]);
    return if @columns < 10;
    my @samples = @columns[9..$#columns];
    if (exists $args{get_columns} && $args{get_columns}){
        my $n = 9;
        my %samp = map {$_ => $n++} @samples;
        return %samp;
    }else{
        return @samples;
    }
}
            
=item B<getInfoFields>

Reads a VCF header and returns a hash of INFO IDs found in the header to anonymous hashes of the values for 'Number', 'Type' and 'Description'. Requires either "vcf" or "header" argument. The former requires a filename while the "header" argument can be either a string or a reference to an array of header lines.

Arguments

=over 16

=item vcf

filename of VCF file to check.

=item header

Header string or an array of header lines in the same order they appear in a file. Ignored if using 'vcf' argument.

=back

 my %info = VcfReader::getInfoFields(vcf => "file.vcf");

=cut
sub getInfoFields{
    #return a hash of INFO IDs, to anon hashes of 
    #Number, Type and Description
    my (%args) = @_;
    my @header = ();
    if ($args{vcf}){
        @header = getHeader($args{vcf});
    }elsif($args{header}){
        if (ref $args{header} eq 'ARRAY'){
            @header = @{$args{header}};
        }else{
            @header = split("\n", $args{header});
        }
    }else{
        croak "getInfoFields method requires either 'vcf' or 'header arguments ";
    }
    my %info = ();
    foreach my $h (@header){
        if ($h =~ /^##INFO=<ID=(\w+),Number=([\.\w+]),Type=(\w+),Description=(.+)>$/){
            $info{$1} = 
                {
                Number => $2,
                Type => $3,
                Description => $4,
                };
        }
    }
    return %info;
}

=item B<getFormatFields>

Reads a VCF header and returns a hash of FORMAT IDs found in the header to anonymous hashes of the values for 'Number', 'Type' and 'Description'. Requires either "vcf" or "header" argument. The former requires a filename while the "header" argument can be either a string or a reference to an array of header lines.

Arguments

=over 16

=item vcf

filename of VCF file to check.

=item header

Header string or an array of header lines in the same order they appear in a file. Ignored if using 'vcf' argument.

=back

 my %format_fields = VcfReader::getFormatFields(vcf => "file.vcf");

=cut
sub getFormatFields{
    #return a hash of INFO IDs, to anon hashes of 
    #Number, Type and Description
    my (%args) = @_;
    my @header = ();
    if ($args{vcf}){
        @header = getHeader($args{vcf});
    }elsif($args{header}){
        if (ref $args{header} eq 'ARRAY'){
            @header = @{$args{header}};
        }else{
            @header = split("\n", $args{header});
        }
    }else{
        croak "getFormatFields method requires either 'vcf' or 'header arguments ";
    }
    my %info = ();
    foreach my $h (@header){
        if ($h =~ /^##FORMAT=<ID=(\w+),Number=([\.\w+]),Type=(\w+),Description=(.+)>$/){
            $info{$1} = 
                {
                Number => $2,
                Type => $3,
                Description => $4,
                };
        }
    }
    return %info;
}
=back



=back

=head2 File Utilities

=over 12

=item B<getContigOrder>

Returns a hash of contig IDs to their relative order in the VCF (i.e. the first contig ID will have a value of 0, the next a value of 1 and so on). 

This function will first attempt to read the contig IDs from a VCF header and failing that it will attempt to read the contig IDs from a VCF file's index. If the index does not exist it will try to create one either using tabix (if input is bgzip compressed) or using VcfReader's own indexing method (if the input is not compressed).

 my %contigs = VcfReader::getContigOrder("file.vcf");

=cut
sub getContigOrder{
    my $vcf = shift;
    croak "getContigOrder method requires one argument (VCF file)" if not $vcf;
    my %contigs = ();
    my @header  = ();
    @header = getMetaHeader($vcf);
    my @con = grep {/##contig=</} @header;
    if (@con){
        my $n = 0;
        foreach my $c (@con){
            if ($c =~/ID=([^,>]+)[>,]/){
                $contigs{$1} = $n++;
            }else{
                carp "ERROR - failed to parse header contig line: $c ";
            }
        }
        return %contigs if %contigs;
    }
    print STDERR "Failed to retrieve contigs from header - reading/creating index.\n";
    if ($vcf =~ /\.(b){0,1}gz$/){
        eval "use Bio::DB::HTS::Tabix; 1" 
            or croak "Bio::DB::HTS::Tabix module is not installed and VCF file $vcf appears to be (b)gzip compressed.  ".
            "  Please install Bio::DB::HTS::Tabix in order to quickly extract contigs from bgzip compressed VCFs.\n";
        my $index = "$vcf.tbi";
        if (not -e $index){
            print STDERR "Indexing $vcf with tabix...\n";
            indexVcf($vcf);
            croak "Tabix indexing failed? $index does not exist " if (not -e $index);
        }
        my $t = getTabixIterator($vcf);
        my $n = 0;
        %contigs = map {$_ => $n++} @{$t->seqnames()};
    }else{
        my %idx = readIndex($vcf);
        foreach my $k (keys %idx){
            if (ref $idx{$k} eq 'HASH' && exists $idx{$k}->{order}){
                $contigs{$k} = $idx{$k}->{order};
            }
        }
    }
    return %contigs;
}
=item B<getContigOrderFromHeader>

Returns a hash of contig IDs to their relative order in the VCF (i.e. the first contig ID will have a value of 0, the next a value of 1 and so on) by reading the header. If contigs can't be found in the header it returns nothing. This can be used instead of "getContigOrder" where the VCF may be unsorted and you do not want to die because it cannot be indexed. Requires a vcf file as an argument. 

 my %contigs = VcfReader::getContigOrderFromHeader(vcf => "file.vcf");

=over 16

=item vcf

File name of VCF file. This argument or 'header' argument is required.

=item header

Header string or an array of header lines in the same order they appear in a file. Ignored if using 'vcf' argument.

=back 

 my %contigs = VcfReader::getContigOrder(file => "file.vcf");

=cut

sub getContigOrderFromHeader{
    my %args = @_;
    croak "getContigOrder method requires file or header argument" 
        if not $args{vcf} and not $args{header};
    my %contigs = ();
    my @header  = ();
    if ($args{vcf}){
        @header = getMetaHeader($args{vcf});
    }elsif($args{header}){
        if (ref $args{header} eq 'ARRAY'){
            @header = @{$args{header}};
        }else{
            @header = split("\n", $args{header});
        }
    }
    my @con = grep {/##contig=</} @header;
    if (@con){
        my $n = 0;
        foreach my $c (@con){
            if ($c =~/ID=([^,>]+)[>,]/){
                $contigs{$1} = $n++;
            }else{
                carp "ERROR - failed to parse header contig line: $c ";
            }
        }
        return %contigs if %contigs;
    }else{
        return;
    }
}

=item B<getLineCount>

Returns the number of lines in a VCF including header lines. If the VCF is not compressed and a VcfReader index (.vridx) exists the line number will be read from the index. Otherwise, a slower sysread method will be used to get the line count. Requires a VCF file as an argument.

 my $total_lines = VcfReader::getLineCount("file.vcf");

=cut
sub getLineCount{
    my $vcf = shift; 
    croak "getLineCount method requires a file as an argument" if not $vcf;
    my $line_count = 0;
    my $FH = _openFileHandle($vcf);
    if ($vcf =~ /\.(b){0,1}gz$/){
       # $line_count++ while (<$FH>);
        $line_count += tr/\n/\n/ while sysread($FH, $_, 2 ** 20);
    }else{
        my $index = "$vcf.vridx";
        if (-e $index){
            $line_count = getFileLengthFromIndex($vcf, $index); 
        }else{
            $line_count += tr/\n/\n/ while sysread($FH, $_, 2 ** 20);
        }
    }
    close $FH;
    return $line_count;
}

=item B<countVariants>

Takes a VCF filename as the only argument and returns the number of variants in the file. This method simply counts the total lines in the VCF by the most efficient means available and subtracts from this the number of header lines.

 my $n = VcfReader::countVariants($vcf);

=cut

sub countVariants{
    my $vcf = shift;
    croak "countVariants method requires a file as an argument" if not $vcf;
    my @head = getHeader($vcf);
    my $all = getLineCount($vcf);
    return $all - @head;
}
=item B<checkCoordinateSorted>

Returns 1 if the given VCF's variants are in coordinate order and all contigs are together. Returns 0 if not in coordinate order or contigs are mixed up. Does not check if contigs are in a particular order relative to one another.

 if (not VcfReader::checkCoordinateSorted($vcf)){
     die "$vcf is not sorted! \n";
 }else{
    VcfReader::indexVcf($vcf);
 }
    
=cut

sub checkCoordinateSorted{
#return 1 if vcf is coordinate sorted (not checking chrom order)
    my ($vcf) = @_;
    my $FH = _openFileHandle($vcf);
    my %contigs = ();
    my $prev_pos = 0;
    while (my $line = <$FH>){
        next if $line =~ /^#/;
        my @split = split("\t", $line);
        if (exists $contigs{$split[0]}){
            if ($contigs{$split[0]}  != scalar(keys%contigs) -1 ){
                return 0; #not sorted - encountered contig twice with another inbetween
            }
            return 0 if $split[1] < $prev_pos;
        }else{
            $contigs{$split[0]}  = scalar(keys%contigs);
        }
        $prev_pos = $split[1];
    }
    return 1;
}

=item B<indexVcf>

Creates either a tabix (.tbi) or VcfReader index (.vridx) for a given VCF file. The file must be sorted in coordinate order. Tabix indexes will be created for bgzip compressed VCFs and VcfReader indexes for uncompressed VCFs. Creation of tabix indexes requires the tabix executable to be in your PATH. These index files allow rapid look up of regions within a VCF. This function croaks upon failure.

 VcfReader::indexVcf("file.vcf");

=cut
sub indexVcf{
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Useqq = 1;
    my ($vcf) = @_;
    if ($vcf =~ /\.(b){0,1}gz$/){
        chomp (my $tabix = `which tabix`);
        croak "Can't find tabix executable to index compressed VCF.  Please ensure it is ".
            "installed and in your PATH or index your VCF with tabix manually. "
            if not $tabix; 
        my $er = `$tabix -p vcf $vcf 2>&1`;
        if ($?){
            if ($? == -1){
                croak "Tabix indexing failed - tabix command failed to execute.\n";
            }
            my $exit = $? >> 8;
            croak "Tabix indexing failed, code $exit: $er\n" ;
        }
        return;
    }
    my $index = "$vcf.vridx";
    my (undef, $tmp_index) = tempfile
    ( 
        "tmp_vridxXXXXX", 
        UNLINK => 1,
        TMPDIR => 1 
    );
    #open (my $INDEX, "+>$index") or croak "can't open $index for writing index: $! ";
    my $gz = new IO::Compress::Gzip $tmp_index
        or croak "IO::Compress::Gzip failed to write to temporary file for ".
        "index: $GzipError\n";
    my $offset = 0;
    my $prev_offset = 0;
    my $prev_pos = 0;
    my %contigs = ();
    my $is_var = 0;
    my $n = 0;
    my $last_line_indexed = 0;
    
    my $FH = _openFileHandle($vcf);
    while (my $line = scalar readline $FH){
        $n++;
        $prev_offset = $offset;
        #print $INDEX pack($pack, $offset);
        $offset = tell $FH;
        next if $line =~ /^#/;
        $is_var++;
        if ($is_var == 1){
            $contigs{first_line} = $n;
            $contigs{first_offset} = $prev_offset;
        }
        my @s = split ("\t", $line, 9);
        my $chrom = $s[VCF_FIELDS->{CHROM}];
        my $pos = $s[VCF_FIELDS->{POS}];
        my $span = getSpan(\@s);
        my $pos_rounddown = int($pos/$REGION_SPANS) * $REGION_SPANS;
        if (exists $contigs{$chrom}){
            if ($contigs{$chrom}->{order}  != scalar(keys%contigs) -1 or $pos < $prev_pos){
                $gz->close();
                croak "Can't index VCF - $vcf not sorted properly ";
            }
            if (exists $contigs{$chrom}->{regions}->{$pos_rounddown}){
                my $merged = 0;
                foreach my $offs (@{$contigs{$chrom}->{regions}->{$pos_rounddown}}){
                    if ($offs->{line_end} +1  eq $n){
                        #if lines are contiguous create a single region
                        $offs->{offset_end} = $offset;
                        $offs->{line_end} = $n;
                        $offs->{pos_end} = $span if ($span > $offs->{pos_end});
                        $merged++;
                        last;
                    }
                }
                if (not $merged){
                    push @{$contigs{$chrom}->{regions}->{$pos_rounddown}},
                        {offset_start=> $prev_offset,  offset_end => $offset,
                        line_start => $n, line_end => $n, pos_start => $pos, pos_end => $span};
                }
            }else{
                push @{$contigs{$chrom}->{regions}->{$pos_rounddown}},
                    {offset_start=> $prev_offset,  offset_end => $offset,
                    line_start => $n, line_end => $n, pos_start => $pos, pos_end => $span};
            }
            foreach my $step (int($pos/$REGION_SPANS) + 1 .. int($span/$REGION_SPANS)){
                my $span_rounddown = $step * $REGION_SPANS;
                if (exists $contigs{$chrom}->{regions}->{$span_rounddown}){
                    my $merged = 0;
                    foreach my $offs (@{$contigs{$chrom}->{regions}->{$span_rounddown}}){
                        if ($offs->{line_end} eq $n){
                            #already merged
                            $merged++;
                            last;
                        }elsif ($offs->{line_end} +1  eq $n){
                            #if lines are contiguous create a single region
                            $offs->{offset_end} = $offset;
                            $offs->{line_end} = $n;
                            $offs->{pos_end} = $span if ($span > $offs->{pos_end});
                            $merged++;
                            last;
                        }
                    }
                    if (not $merged){
                        push @{$contigs{$chrom}->{regions}->{$span_rounddown}},
                            {offset_start=> $prev_offset,  offset_end => $offset,
                            line_start => $n, line_end => $n, pos_start => $pos, pos_end => $span};
                    }
                }else{
                    push @{$contigs{$chrom}->{regions}->{$span_rounddown}},
                        {offset_start=> $prev_offset,  offset_end => $offset,
                        line_start => $n, line_end => $n, pos_start => $pos, pos_end => $span};
                }
            }
        }else{
            $contigs{$chrom}->{order}  = scalar(keys%contigs);
            push @{$contigs{$chrom}->{regions}->{$pos_rounddown}},
                {offset_start=> $prev_offset,  offset_end => $offset,
                line_start => $n, line_end => $n, pos_start => $pos, pos_end => $span};
        }
        $prev_pos = $pos;
    }
    foreach my $k (keys %contigs){
	next if ref $contigs{$k} ne 'HASH';
	next if not exists $contigs{$k}->{regions};
        foreach my $r (keys %{$contigs{$k}->{regions}}){
            foreach my $s (@{$contigs{$k}->{regions}->{$r}}){
                if (exists $s->{line_start}){
                    delete $s->{line_start};
                }
                if (exists $s->{line_end}){
                    delete $s->{line_end};
                }
            }
        }
    }
    $contigs{last_line} = $n;
    $contigs{last_offset} = $prev_offset;
    close $FH;
    print $gz Dumper \%contigs;
    close $gz;
    move($tmp_index, $index) or croak "Could not create index '$index' from temporary index file: $! ";
}

=item B<readIndex>

For uncompressed VCFs this function reads the VcfReader index (.vridx), creating it if it does not already exist, and returns the data structure contained within. The hash data structure returned by this function can be used by the search functions in this module (see below). 

For bgzip compressed VCFs this function will create a Tabix index (.tbi) if does not already exist and return a hash of contig names to relative orders within the VCF. This method is primarily meant for use with uncompressed VCFs.

Requires a VCF filename as the only argument.

 my %index = VcfReader::readIndex('file.vcf');
 my %search_arguments = VcfReader::getSearchArguments('file.vcf', \%index);
 my @hits = VcfReader::searchForPosition(%search_arguments, chrom => 1, pos => 1000000);


=cut
sub readIndex{
    my ($vcf) = @_;
    my %contigs = ();
    if ($vcf =~/\.(b){0,1}gz$/){
        #if compressed just create index if it doesn't exist and return
        my $index = "$vcf.tbi"; 
        if (not -e $index){
            print STDERR "$index does not exist - indexing $vcf...\n";
            indexVcf($vcf);
            croak "Indexing failed? $index does not exist " if (not -e $index);
            print STDERR " Done.\n";
        }else{
            carp "\nWARNING: Tabix index $index is older than $vcf " if (-M $vcf) < (-M $index); 
        }
        eval "use Bio::DB::HTS::Tabix; 1" 
            or croak "Bio::DB::HTS::Tabix module is not installed and VCF file $vcf appears to be (b)gzip compressed.  ".
            "  Please install Bio::DB::HTS::Tabix in order to read index from bgzip compressed VCFs.\n";
        my $t = getTabixIterator($vcf);
        my $n = 0;
        %contigs = map {$_ => $n++} @{$t->seqnames()};
        return %contigs;
    }
    my $index = "$vcf.vridx"; 
    my $block_dump;
    if (not -e $index){
        print STDERR "$index does not exist - indexing $vcf...\n";
        indexVcf($vcf);
        croak "Indexing failed? $index does not exist " if (not -e $index);
        print STDERR " Done.\n";
    }else{
        carp "\nWARNING: VcfReader index $index is older than $vcf " if (-M $vcf) < (-M $index); 
    }
    my $z = new IO::Uncompress::Gunzip $index
        or die "gunzip failed to read index $index: $GunzipError\n";
    {
        local $/;
        $block_dump = <$z>;
    }
    close ($z);
    %contigs = %{ eval $block_dump };
    return %contigs;
}


=item B<getFileLengthFromIndex>

For uncompressed VCFs, this function reads the VcfReader index (.vridx) and returns the line number of the last line of the file. This cannot be used on compressed VCFs. Reading in the VcfReader index can be memory intensive and slow for large files so if you have already read the index elsewhere in your program you should just look up the 'last_line' key from that hash to save resources. If you want to avoid creating a non-existing .vridx or your file is not sorted use the 'getLineCount' function instead.

Requires a VCF filename as the only argument.

 my $length = VcfReader::getFileLengthFromIndex('file.vcf');
 print "file.vcf has $length lines\n";

=cut
sub getFileLengthFromIndex{
    my $vcf = shift;
    if ($vcf =~ /\.(b){0,1}gz$/){
        carp "Can't use getFileLengthFromIndex function on (b)gzip compressed VCFs.\n";
        return;
    }
    my %idx = readIndex($vcf);
    return $idx{last_line};
}

=item B<openVcf>

Convenience method to return a filehandle for reading a VCF. Requires a filename or filehandle as the only input. 

If the filename ends in '.bgz' or '.gz' it will choose the fastest available method to read the file in the order of: piping from gzip (fastest), using Compress::BGZF::Reader (marginally faster than IO::Uncompress::Gunzip) or finally, using IO::Uncompress::Gunzip in MultiStream mode (slowest).

 my $FH1 = VcfReader::openVcf('file1.vcf');
 my $FH2 = VcfReader::openVcf('file2.vcf.gz');

=cut

sub openVcf{
    my $vcf = shift;
    croak "openVcf method requires a filename as an argument" if not $vcf;
    return _openFileHandle($vcf);
}

sub _openFileHandle{
    my $vcf = shift;
    croak "_openFileHandle method requires a file or filehandle as an argument" if not $vcf;
    my $FH; 
    if (openhandle($vcf) ){
        return $vcf;#already an open filehandle
    }
    if ($vcf =~ /\.(b){0,1}gz$/){
        $FH = $getUncompressFilehandle->($vcf);
    }else{
        open ($FH, $vcf) or croak "Failed to open $vcf for reading: $! ";
    }
    return $FH;
}

=back

=head2 Variant Utilities

The following utilities are used for parsing individual lines from a VCF. They expect the line to be passed as a reference to an array created by chomping and splitting the line on tab delimiters. For example:

 while (<VCF>){
    chomp;
    my @line = split(/\t/); 
    my $ref_allele = VcfReader::getVariantField(\@line, 'REF');
    ...
 }

=over 12 

=item B<getVariantField>

Retrieves the value for a given field from a given line. The first value passed should be an array reference to a split line and the second should be the name of the field to retrieve (e.g. CHROM, POS, ID, REF, ALT, QUAL, FILTER, INFO, FORMAT). 
 
 my $position = VcfReader::getVariantField(\@split_line, 'POS');

 my $id = VcfReader::getVariantField(\@split_line, 'ID');

=cut
sub getVariantField{
    my ($split, $field) = @_;
    $field =~ s/^#+//;
    croak "line passed to getVariantField must be an array reference " if ref $split ne 'ARRAY';
    croak "Invalid field ($field) passed to getVariantField method " 
        if not exists VCF_FIELDS->{$field};
    if (VCF_FIELDS->{$field} > $#{$split}){
        if ($field eq 'FORMAT'){
            #carp "No FORMAT field for line " . join("\t", @split) . " " ;
            return;
        }else{
            croak "Line has too few fields: " . join("\t", @$split) . " " ;
        }
    }
    return $split->[VCF_FIELDS->{$field}];
}

=item B<getMultipleVariantFields>

Retrieves the value for given fields from a given line. The first value passed should be an array reference to a split line and the remaining values should be the names of fields to retrieve (e.g. CHROM, POS, ID, REF, ALT, QUAL, FILTER, INFO, FORMAT). 
 
 my ($QUAL, INFO) = VcfReader::getMultipleVariantFields(\@split_line, 'QUAL', 'INFO');


=cut
sub getMultipleVariantFields{
    my $split = shift;
    my @values = ();
    while (my $field = shift){
        push @values, getVariantField($split, $field); 
    }
    return @values;
}
 
=item B<getVariantInfoField>

Retrieves the value for a given INFO field from a given line. Returns the value of the INFO field if found and the INFO field has a value, returns 1 if the INFO field is found and is a flag and returns nothing if the INFO field is not found. The first value passed should be an array reference to a split line and the second should be the name of the INFO field to retrieve.

 my $af = VcfReader::getVariantInfoField(\@split_line, 'AF');

=cut
sub getVariantInfoField{
    my ($line, $info_field) = @_;
    my @info = split(';', $line->[VCF_FIELDS->{INFO}]);
    foreach my $inf (@info){
        if ($inf =~ /^$info_field=(.+)/){
            return $1;
        }elsif ($inf eq $info_field){
            return 1;
        }
    }
    return;
}

=item B<addVariantInfoField>

For a given line adds specified INFO field, replacing any pre-existing INFO fields that share the same ID. Returns an array reference to a split line with the INFO field ammended accordingly.

Arguments

=over 16

=item line

An array reference to a split VCF line. Required.

=item id

The INFO field ID to add/replace. Required.

=item value

The value for the given ID. If the INFO field is a FLAG this value should be ommited. 

=back

 
 my $modified_line = VcfReader::addVariantInfoField
    (
        line =>\@line, 
        id => 'SOMEFLAG', 
    );

 my $modified_line = VcfReader::addVariantInfoField
    (
        line =>\@line, 
        id => 'SOMEFIELD',
        value => 0.111,
    );

=cut

sub addVariantInfoField{
    my (%args) = @_;
    croak "line argument is required for addVariantInfoField method " if not defined $args{line};
    croak "line argument must be an array reference " if ref $args{line} ne 'ARRAY';
    croak "id argument is required for addVariantInfoField method " if not defined $args{id};
    if ($args{id} =~ /[,;]/){
        croak "id ($args{id}) passed to addVariantInfoField method has invalid characters.\n";
    }
    if (defined $args{value} && $args{value} =~ /;/){
        croak "value ($args{value}) passed to addVariantInfoField method has invalid characters.\n";
    }
    my @info = split(";", getVariantField($args{line}, 'INFO'));
    my @new_inf = ();
    foreach my $inf (@info){
        if ($inf ne $args{id} and $inf !~ /^$args{id}=/){
            push @new_inf, $inf;
        }
    }
    if (defined $args{value}){
        push @new_inf, "$args{id}=$args{value}";
    }else{
        push @new_inf, $args{id}; 
    }
    return replaceVariantField($args{line}, 'INFO', join(";", @new_inf));
}

=item B<addVariantFilterField>

For a given line adds specified FILTER field. Returns an array reference to a split line with the INFO field ammended accordingly. Default behaviour is to append the FILTER field, which can be modified with the 'replace' argument.

Arguments

=over 16

=item line

An array reference to a split VCF line. Required.

=item id

The FILTER field ID to add/replace. Required.

=item replace

If true any existing FILTER field will be replaced rather than appended to.  

=item match_replace

Only replace if the FILTER field matches this value, otherwise append.

=back

 
 my $modified_line = VcfReader::addVariantInfoField
    (
        line =>\@line, 
        id => 'SOMEFILTER', 
    );

 my $modified_line = VcfReader::addVariantInfoField
    (
        line =>\@line, 
        id => 'SOMEFILTER', 
        replace => 1,
    );

 my $modified_line = VcfReader::addVariantInfoField
    (
        line =>\@line, 
        id => 'SOMEFILTER', 
        match_replace => 'PASS'
    );



=cut

sub addVariantFilterField{
    my (%args) = @_;
    croak "line argument is required for addVariantInfoField method " if not defined $args{line};
    croak "line argument must be an array reference " if ref $args{line} ne 'ARRAY';
    croak "id argument is required for addVariantInfoField method " if not defined $args{id};
    if ($args{id} =~ /[,;]/){
        croak "id ($args{id}) passed to addVariantInfoField method has invalid characters.\n";
    }
    if ($args{replace}){
        return replaceVariantField($args{line}, 'FILTER', $args{id});
    }else{
        my $filter = getVariantField($args{line}, 'FILTER');
        if ($filter ne '.'){ 
            if ($args{match_replace} and $filter eq $args{match_replace}){
                $filter = $args{id};
            }else{
                $filter = "$args{id};$filter";
            }
        }else{
            $filter = $args{id};
        }
        return replaceVariantField($args{line}, 'FILTER', $filter);
        
    }
}


=item B<readAlleles>

Returns an array of all alleles in a given VCF line (i.e. the alleles found in REF and ALT columns). Requires an array reference to a split line to be passed as the 'line' argument. Optionally takes 'alt_alleles' argument, which if true will cause the function to only return alleles from the ALT column. Default is to retrieve alleles from both REF and ALT columns. Alleles will be maintained in the order from the VCF.

Arguments

=over 16

=item line

An array reference to a split VCF line. Required.

=item alt_alleles

If true, only alleles in the ALT column will be returned.

=back

 my @alleles = VcfReader::readAlleles(line => \@split_line);

 my @alts = VcfReader::readAlleles(line => \@split_line, alt_alleles => 1);

=cut
sub readAlleles{
    my (%args) = @_;
    croak "line argument is required for readAlleles method " if not defined $args{line};
    croak "line argument must be an array reference " if ref $args{line} ne 'ARRAY';
    my @alleles = split(",", getVariantField($args{line}, "ALT"));
    #if no variant at position then ALT will be "." and we want to remove it from our alleles array
    @alleles = grep {! /\./ } @alleles; 
    if (defined $args{alt_alleles} && $args{alt_alleles}){
        return @alleles if defined wantarray;
        carp "readAlleles method called in void context ";
    }
    unshift(@alleles, getVariantField($args{line}, "REF"));
    #now ref is at index 0 of @alleles, and the alts correspond to the number in the call field
    return @alleles if defined wantarray;
    carp "readAlleles method called in void context ";
}

=item B<isMultiAllelic>

Takes an array reference to a split line and returns 1 if there is more than one ALT allele. Otherwise returns 0.

 if (VcfReader::isMultiAllelic(\@split_line)){
     print "Line has more than one ALT alleles.";
 }

=cut
sub isMultiAllelic{
    my ($line) = @_;
    my $alts = readAlleles(line => $line, alt_alleles => 1);
    return 1 if $alts > 1;
    return 0;
}

=item B<getVariantFormatFields>

Returns a hash of the different fields found in the FORMAT column for a variant with the key being the name of the field and the value being the 0-based order in which it occurs unless called in a scalar context in which case the number of FORMAT fields will be returned. Requires an array reference to a split line to be passed as the only argument.

 my %format = VcfReader::getVariantFormatFields(\@split_line);

=cut
sub getVariantFormatFields{
    my ($line) = @_;
    my $format = $line->[VCF_FIELDS->{FORMAT}];
    if (not defined $format){
        return;
    }
    my @form = split(":", $format);
    my %format_fields = ();
    my $i = 0;
    foreach my $f (@form){
        $format_fields{$f} = $i++;
    }
    return %format_fields if wantarray;
    return @form if defined wantarray;
    carp "getVariantFormatFields method called in void context ";
}

=item B<getAllSampleVariants>

Returns an array of all sample genotype columns in the order they appear in the VCF. Requires an array reference to a split line to be passed as the first and only argument. 

 my @calls = VcfReader::getAllSampleVariants(\@line);

=cut

sub getAllSampleVariants{
    my ($line) = @_;
    croak "Line has too few fields: " . join("\t", @$line) . " " if 9 > $#{$line};
    return @$line[9 .. $#{$line} ] ;
}


=item B<getSampleVariant>

Returns a genotype column from a variant. Requires an array reference to a split line to be passed as the first argument. The optional second argument is the 0-based column number to retrieve the genotype from. If there is no second argument the first sample genotype column will be returned. Column numbers for samples can be obtained from the 'getSamples' function.

 my $call = VcfReader::getSampleVariant(\@line);

 my %samples_to_columns = VcfReader::getSamples(vcf => "file.vcf", get_columns => 1);
 my $sample_call = VcfReader::getSampleVariant(\@line, $samples_to_columns{$sample_name});


=cut
sub getSampleVariant{
    my ($line, $column) = @_;
    croak "Invalid column ($column) for getSampleVariant - " .
        "samples are only present in columns 10 and onwards.\n"
        if $column < 9;
    if ($column){
        croak "Line has too few fields: " . join("\t", @$line) . " " if $column > $#{$line};
        return $line->[$column];
    }else{#otherwise just return first sample
        croak "Line has too few fields: " . join("\t", @$line) . " " if 9 > $#{$line};
        return $line->[9];
    }
}

=item B<getSampleGenotypeField>

Can be used to return the value for a genotype field (e.g. "GT", "GQ", "AD", "PL") field for one sample, a list of samples or all samples in a VCF.

Arguments:

=over 16

=item line

Array reference to a split line to be passed as the first argument. Required.

=item field

Name of genotype field to retrieve (e.g. "GT" or "AD"). Case-sensitive.

=item column

Single column number (0-based) to retrieve genotype field from. A single genotype will be returned as a string.

=item sample

Single sample to retrieve genotype field from. If used in conjunction with "sample_to_columns" argument this value is assumed to be a sample name. Otherwise it is assumed to be a column number. A single genotype field will be returned as a string. Overrides column argument.

=item multiple

A reference to an array of samples to retrieve variants from. If used in conjunction with "sample_to_columns" argument the values are assumed to be sample names. Otherwise they are assumed to be column numbers. A hash will be returned with sample identifiers (sample names or column numbers) as keys and the genotype field as values. Overrides "sample" or "column" arguments.

=item all

If true, genotype fields for all samples will be returned in a hash as per the above 'multiple' option. You can use the "sample_to_columns" argument in order to use sample names as the keys in the returned hash, otherwise column numbers will be used.

=item sample_to_columns

A reference to a hash of sample names to 0-based column numbers as generated by the "getSamples" method. Use this to use sample names rather than column numbers with "sample", "multiple" or "all" options.

=back

 my $gt = VcfReader::getSampleGenotypeField
          (
               line => \@line, 
               field => "GT",
               sample => 9
          );

 my $gq = VcfReader::getSampleGenotypeField
          (
               line => \@line, 
               field => "GQ",
               sample => "sample_A", 
               sample_to_columns => \%samples_to_columns
          );

 my %col_to_ad = VcfReader::getSampleGenotypeField
          (
               line => \@line, 
               field => "AD",
               multiple => [9, 11, 12],
          );

 my %samp_to_ad = VcfReader::getSampleGenotypeField
          (
               line => \@line, 
               field => "AD",
               multiple => ["sample_A", "sample_B", "sample_C"],
               sample_to_columns => \%samples_to_columns
          );

 my %col_to_gq = VcfReader::getSampleGenotypeField
          (
               line => \@line, 
               field => "GQ",
               all => 1,
          );

 my %samp_to_gq = VcfReader::getSampleGenotypeField
          (
               line => \@line, 
               field => "GQ",
               all => 1,
               sample_to_columns => \%samples_to_columns
          );

=cut
sub getSampleGenotypeField{
#returns scalar value for genotype field 
#unless multiple argument is used in which
#case a hash of sample=>value key/values is returned
#assumes identifier is column unless a hash of sample names to columns
#is provided as "sample_to_columns" argument, in which case identifier is assumed to be sample ID
#column can be used as an argument instead of sample to explicitly specify it as a column rather than id
    my (%args) = @_;
    croak "\"field\" argument must be passed to getSampleGenotypeField - e.g. getSampleGenotypeField(field=>\"GQ\") " if not defined $args{field};
    croak "\"line\" argument must be passed to getSampleGenotypeField " if not defined $args{line};
    carp "WARNING Both multiple and sample arguments supplied to getSampleGenotypeField method - only multiple argument will be used " if (defined $args{multiple} and defined $args{sample});
    carp "WARNING Both multiple and column arguments supplied to getSampleGenotypeField method - only multiple argument will be used " if (defined $args{multiple} and defined $args{column});
    if (defined $args{sample_to_columns}){
        if (ref $args{sample_to_columns} ne 'HASH'){
            croak "\"sample_to_columns\" argument passed to getSampleGenotypeField must be a hash reference ";
        }
    #}elsif(defined $args{sample} or $args{multiple}){
#        croak "\"multiple\" and \"sample\" arguments can only be used in conjunction with \"sample_to_columns\" option for getSampleGenotypeField method ";
    }
    my %var_format = getVariantFormatFields($args{line});
    if (not defined $var_format{$args{field}}){
        carp "Field $args{field} not found for getSampleGenotypeField ";
        return;
    }
    #croak "Line has too few fields: " . join("\t", @split) . " " if $self->{_samples}->{$sample} > $#split;
    my $var; 
    if ($args{all}){
        my %values = ();
        if (defined $args{sample_to_columns}){
            foreach my $sample (keys %{$args{sample_to_columns}}){
                my $mvar = getSampleVariant(
                                    $args{line}, 
                                    $args{sample_to_columns}->{$sample},
                                    );
                my $value = (split ":", $mvar)[$var_format{$args{field}}];
                $values{$sample} =  $value;
            }
        }else{
            foreach my $col (9..$#{$args{line}}){
                my $mvar = getSampleVariant(
                                    $args{line}, 
                                    $col,
                                    );
                my $value = (split ":", $mvar)[$var_format{$args{field}}];
                $values{$col} =  $value;

            }
        }
        return %values if defined wantarray;
        carp "getSampleGenotypeField called in a void context ";
    }elsif($args{multiple}){
        croak "multiple argument must be an array reference " if ref $args{multiple} ne 'ARRAY';
        my %values = ();
        foreach my $sample (@{$args{multiple}}){
            if (defined $args{sample_to_columns}){
                my $mvar = getSampleVariant(
                                    $args{line}, 
                                    $args{sample_to_columns}->{$sample},
                                    );
                my $value = (split ":", $mvar)[$var_format{$args{field}}];
                $values{$sample} =  $value;
            }else{
                my $mvar = getSampleVariant(
                                    $args{line}, 
                                    $sample,
                                    );
                my $value = (split ":", $mvar)[$var_format{$args{field}}];
                $values{$sample} =  $value;
            }
        }
        return %values if defined wantarray;
        carp "getSampleGenotypeField called in a void context ";
    }elsif (defined $args{sample}){
        my $col = $args{sample};
        if (defined $args{sample_to_columns}){
            $col = $args{sample_to_columns}->{$args{sample}};
        }
        $var = getSampleVariant(
                            $args{line}, 
                            $args{sample_to_columns}->{$args{sample}},
                            );
    }elsif (defined $args{column}){
        $var = getSampleVariant(
                                $args{line}, 
                                $args{column},
                                );
    }else{#otherwise just look at first sample
        $var = getSampleVariant($args{line});
    }
    return if not defined $var and defined wantarray;
    my $value = (split ":", $var)[$var_format{$args{field}}];
    return $value if defined wantarray;
    carp "getSampleGenotypeField called in a void context ";
}


=item B<getSampleCall>

Returns the called genotype (i.e. the GT genotype field) for one or multiple samples.

Arguments:

=over 16

=item line

Array reference to a split line to be passed as the first argument. Required.

=item minGQ

Minimum genotype quality. If the genotype quality (GQ) field for a sample is less than this value then a no call ("./.") will be assigned to that sample. If the GQ field is absent the function will carp annoyingly and return no calls for samples.

=item return_alleles_only 

If true this argument will cause the function to return and array of allele codes found for given samples, not genotypes. No calls are represented by '.' characters. 

=item column

Single column number (0-based) to retrieve genotype from. A single genotype will be returned as a string.

=item sample

Single sample to retrieve genotype from. If used in conjunction with "sample_to_columns" argument this value is assumed to be a sample name. Otherwise it is assumed to be a column number. A single genotype field will be returned as a string. Overrides column argument.

=item multiple

A reference to an array of samples to retrieve variants from. If used in conjunction with "sample_to_columns" argument the values are assumed to be sample names. Otherwise they are assumed to be column numbers. A hash will be returned with sample identifiers (sample names or column numbers) as keys and the genotypes as values. Overrides "sample" or "column" arguments.

=item all

If true, genotypes for all samples will be returned in a hash as per the above 'multiple' option. You can use the "sample_to_columns" argument in order to use sample names as the keys in the returned hash, otherwise column numbers will be used.

=item sample_to_columns

A reference to a hash of sample names to 0-based column numbers as generated by the "getSamples" method. Use this to use sample names rather than column numbers with "sample", "multiple" or "all" options.

=back

 my $gt         = VcfReader::getSampleCall
                  (
                      line => \@line, 
                      sample => 9
                  );

 my $gt         = VcfReader::getSampleCall
                  (          
                      line => \@line, 
                      sample => "sample_A", 
                      minGQ => 30,
                      sample_to_columns => \%samples_to_columns
                  );

 my %col_to_gt  = VcfReader::getSampleCall
                  (
                      line => \@line, 
                      multiple => [9, 11, 12],
                  );

 my %samp_to_gt = VcfReader::getSampleCall
                  (
                      line => \@line, 
                      multiple => ["sample_A", "sample_B", "sample_C"],
                      sample_to_columns => \%samples_to_columns
                  );

 my %col_to_gt  = VcfReader::getSampleCall
                  (
                      line => \@line, 
                      all => 1,
                  );

 my %samp_to_gt = VcfReader::getSampleCall
                  (
                      line => \@line, 
                      all => 1,
                      sample_to_columns => \%samples_to_columns
                  );

 my %samp_to_gt = VcfReader::getSampleCall
                  (
                      line => \@line, 
                      minGQ => 30,
                      all => 1,
                      sample_to_columns => \%samples_to_columns
                  );

 my @alleles    = VcfReader::getSampleCall
                  (
                      line => \@line, 
                      minGQ => 30,
                      all => 1,
                      return_alleles_only => 1
                  );


=cut
sub getSampleCall{
#returns scalar value for genotype called 
#unless multiple argument is used in which
#case a hash of sample=>call key/values is returned
#returns './.' for samples below $args{minGQ}
#use return_alleles_only => 1 to only return allele codes, not genotypes (always returns an array)
    my (%args) = @_;
    croak "\"line\" argument must be passed to getSampleCall " 
        if not defined $args{line};
    carp "WARNING Both multiple and sample arguments supplied to ".
         "getSampleCall method - only multiple argument will be used " 
            if (defined $args{multiple} and defined $args{sample});
    if (defined $args{sample_to_columns}){
        if (ref $args{sample_to_columns} ne 'HASH'){
            croak "\"sample_to_columns\" argument passed to getSampleCall ".
                  "must be a hash reference ";
        }
    }
    my $var; 
    my %calls = ();
    if ($args{all}){
        if (defined $args{sample_to_columns}){
            foreach my $sample (keys %{$args{sample_to_columns}}){
                $calls{$sample} = _getGenotype
                (
                    $args{line},
                    $args{sample_to_columns}->{$sample}, 
                    $args{minGQ}
                );
            }
        }else{
            foreach my $col (9..$#{$args{line}}){
                $calls{$col} = _getGenotype
                (
                    $args{line},
                    $col, 
                    $args{minGQ}
                );
            }
        }
        if ($args{return_alleles_only}){
            my %rev_calls = reverse %calls;
            my %allele_codes = ();
            foreach my $g ( keys %rev_calls){
                my @al = split(/[\/\|]/, $g);
                foreach my $a (@al){
                    $allele_codes{$a}++;
                }
            }
                return keys %allele_codes if defined wantarray;
        }else{
            return %calls if defined wantarray;
        }
        carp "getSampleCall called in a void context ";
    }elsif($args{multiple}){
        croak "multiple argument must be an array reference " if ref $args{multiple} ne 'ARRAY';
        if (defined $args{sample_to_columns}){
            foreach my $sample (@{$args{multiple}}){
                croak "Sample \"$sample\" does not exist in samples_to_columns hash passed to getSampleCall " 
                    if not exists $args{sample_to_columns}->{$sample};
                $calls{$sample} = _getGenotype
                (
                    $args{line},
                    $args{sample_to_columns}->{$sample}, 
                    $args{minGQ}
                );
            }
        }else{
            foreach my $col (@{$args{multiple}}){
                if ($col !~ /^\d+$/){
                    croak "columns passed to getSampleCall must be integers not \"$col\". ".
                    "To parse sample names you must pass a hash reference of sample IDs ".
                    "to columns as generated by the getSamples sub as the sample_to_columns argument ";
                }
                $calls{$col} = _getGenotype 
                (
                    $args{line},
                    $col, 
                    $args{minGQ}
                );
            }
        }
        if ($args{return_alleles_only}){
            my %rev_calls = reverse %calls;
            my %allele_codes = ();
            foreach my $g ( keys %rev_calls){
                my @al = split(/[\/\|]/, $g);
                foreach my $a (@al){
                    $allele_codes{$a}++;
                }
            }
                return keys %allele_codes if defined wantarray;
        }else{
            return %calls if defined wantarray;
        }
        carp "getSampleCall called in a void context ";
    }else{
        my $call;
        my $col = 9;#default is to get first sample
        if (defined $args{sample}){
            if (defined $args{sample_to_columns}){
                if (not exists $args{sample_to_columns}->{$args{sample}}){
                    croak "Sample \"$args{sample}\" does not exist in samples_to_columns hash passed to getSampleCall " 
                }
                $col = $args{sample_to_columns}->{$args{sample}};
            }else{
                $col = $args{sample};
            }
        }elsif (defined $args{column}){
            $col = $args{column};
        }
        $call = _getGenotype
        (
            $args{line},
            $col,
            $args{minGQ}
        );
        if ($args{return_alleles_only}){
            if ($call eq './.'){
                return '.' if defined wantarray;
            }
            my @al = split(/[\/\|]/, $call);
            return @al if defined wantarray;
        }else{
            return $call if defined wantarray;
        }
    }
    carp "getSampleCall called in a void context ";
}


=item B<getSampleActualGenotypes>

Behaves exactly as the getSampleCall function but returns genotypes using the actual alleles found in REF and ALT (e.g. "C/G") rather than call codes (e.g. "0/1"). See getSampleCall arguments.

 my $gt         = VcfReader::getSampleActualGenotypes
                  (
                      line => \@line, 
                      column => 9
                  );

 my $gt         = VcfReader::getSampleActualGenotypes
                  (
                      line => \@line, 
                      sample => "sample_A", 
                      minGQ => 30,
                      sample_to_columns => \%samples_to_columns
                  );

 my %col_to_gt  = VcfReader::getSampleActualGenotypes
                  (
                      line => \@line, 
                      multiple => [9, 11, 12],
                  );

 my %samp_to_gt = VcfReader::getSampleActualGenotypes
                  (
                      line => \@line, 
                      multiple => ["sample_A", "sample_B", "sample_C"],
                      sample_to_columns => \%samples_to_columns
                  );

 my %col_to_gt  = VcfReader::getSampleActualGenotypes
                  (
                      line => \@line, 
                      all => 1,
                  );

 my %samp_to_gt = VcfReader::getSampleActualGenotypes
                  (
                      line => \@line, 
                      all => 1,
                      sample_to_columns => \%samples_to_columns
                  );

 my @alleles    = VcfReader::getSampleActualGenotypes
                  (
                      line => \@line, 
                      all => 1,
                      return_alleles_only => 1
                  );


=cut
sub getSampleActualGenotypes{
    my (%args) = @_;
    croak "\"line\" argument must be passed to getSampleActualGenotypes " if not defined $args{line};
    carp "WARNING Both multiple and sample arguments supplied to getSampleActualGenotypes method - only multiple argument will be used " if (defined $args{multiple} and defined $args{sample});
    if (defined $args{sample_to_columns}){
        if (ref $args{sample_to_columns} ne 'HASH'){
            croak "\"sample_to_columns\" argument passed to getSampleActualGenotypes must be a hash reference ";
        }
    #}elsif(defined $args{sample} or $args{multiple}){
    #    croak "\"multiple\" and \"sample\" arguments can only be used in conjunction with \"sample_to_columns\" option for getSampleCall method ";
    }
    my @alleles = readAlleles(line => $args{line});
    my %multiple = ();
    my $genotype;
    my @sample_alleles = ();
    if ($args{all}){
        if (defined $args{sample_to_columns}){
            foreach my $sample (keys %{$args{sample_to_columns}}){
                my $call = _getGenotype
                (   $args{line}, 
                    $args{sample_to_columns}->{$sample},
                    $args{minGQ}
                );
                if ($call =~ /(\d+)([\/\|])(\d+)/){
                    if ($args{return_alleles_only}){
                        push (@sample_alleles, ($alleles[$1], $alleles[$3]));
                    }else{
                        $multiple{$sample} = "$alleles[$1]$2$alleles[$3]";
                    }
                }else{
                    if (not $args{return_alleles_only}){
                        $multiple{$sample} = "-/-";
                    }
                }
            }
        }else{
            foreach my $col (9..$#{$args{line}}){
                my $call = _getGenotype
                (   $args{line}, 
                    $col,
                    $args{minGQ}
                );
                if ($call =~ /(\d+)([\/\|])(\d+)/){
                    if ($args{return_alleles_only}){
                        push (@sample_alleles, ($alleles[$1], $alleles[$3]));
                    }else{
                        $multiple{$col} = "$alleles[$1]$2$alleles[$3]";
                    }
                }else{
                    if (not $args{return_alleles_only}){
                        $multiple{$col} = "-/-";
                    }
                }
            }
        }
        if ($args{return_alleles_only}){
            my %seen = ();
            @sample_alleles = grep {!$seen{$_}++} @sample_alleles;#remove duplicates
            return @sample_alleles;
        }else{
            return %multiple;
        }
    }elsif($args{multiple}){
        croak "multiple argument must be an array reference " if ref $args{multiple} ne 'ARRAY';
        if (defined $args{sample_to_columns}){
            foreach my $sample (@{$args{multiple}}){
                my $call = _getGenotype
                (   $args{line}, 
                    $args{sample_to_columns}->{$sample},
                    $args{minGQ}
                );
                if ($call =~ /(\d+)([\/\|])(\d+)/){
                    if ($args{return_alleles_only}){
                        push (@sample_alleles, ($alleles[$1], $alleles[$3]));
                    }else{
                        $multiple{$sample} = "$alleles[$1]$2$alleles[$3]";
                    }
                }else{
                    if (not $args{return_alleles_only}){
                        $multiple{$sample} = "-/-";
                    }
                }
            }
        }else{
            foreach my $col (@{$args{multiple}}){
                my $call = _getGenotype
                (   $args{line}, 
                    $col,
                    $args{minGQ}
                );
                if ($call =~ /(\d+)([\/\|])(\d+)/){
                    if ($args{return_alleles_only}){
                        push (@sample_alleles, ($alleles[$1], $alleles[$3]));
                    }else{
                        $multiple{$col} = "$alleles[$1]$2$alleles[$3]";
                    }
                }else{
                    if (not $args{return_alleles_only}){
                        $multiple{$col} = "-/-";
                    }
                }
            }
        }
        if ($args{return_alleles_only}){
            my %seen = ();
            @sample_alleles = grep {!$seen{$_}++} @sample_alleles;#remove duplicates
            return @sample_alleles;
        }else{
            return %multiple;
        }
    }else{
        my $col = 9;
        if ($args{sample}){
            if (defined $args{sample_to_columns}){
                $col = $args{sample_to_columns}->{$args{sample}};
            }else{
                $col = $args{sample};
            }
        }elsif ($args{column}){
            $col = $args{column};
        }
        my $call = _getGenotype
        (   $args{line}, 
            $col,
            $args{minGQ}
        );
        if ($call =~ /(\d+)([\/\|])(\d+)/){
            if ($args{return_alleles_only}){
                push (@sample_alleles, ($alleles[$1], $alleles[$3]));
                my %seen = ();
                @sample_alleles = grep {!$seen{$_}++} @sample_alleles;#remove duplicates
                return @sample_alleles;
                
            }else{
                $genotype = "$alleles[$1]$2$alleles[$3]";
            }
        }else{
            $genotype = "-/-";
        }
        return if $args{return_alleles_only};
        return $genotype 
    }
}

=item B<getSampleAlleleDepths>

Calculates depth for each allele for a sample call using AD or AO/RO genotype fields.

Arguments:

=over 16

=item line

Array reference to a split line to be passed as the first argument. Required.

=item column

Single column number (0-based) to retrieve genotype field from. A single genotype will be returned as a string.

=item sample

Single sample to retrieve genotype field from. If used in conjunction with "sample_to_columns" argument this value is assumed to be a sample name. Otherwise it is assumed to be a column number. A single genotype field will be returned as a string. Overrides column argument.

=item sample_to_columns

A reference to a hash of sample names to 0-based column numbers as generated by the "getSamples" method. Use this to use sample names rather than column numbers with "sample", "multiple" or "all" options.

=back

 my @ads = VcfReader::getSampleAlleleDepths
          (
               line   => \@line, 
               column => 9
          );

=cut
sub getSampleAlleleDepths{
#returns array of allele depths for REF and ALT alleles for given sample
    my (%args) = @_;
    croak "\"line\" argument must be passed to getSampleAlleleDepths " if not defined $args{line};
    croak "\"column\" or \"sample\" argument must be passed to getSampleAlleleDepths " if not defined $args{sample} and not defined $args{column};
    if ($args{sample}){
        if (not $args{sample_to_columns}){
            croak "\"sample\" argument must be used in conjunction with \"sample_to_columns\" argument ";
        }
    }
    if (defined $args{sample_to_columns}){
        if (ref $args{sample_to_columns} ne 'HASH'){
            croak "\"sample_to_columns\" argument passed to getSampleAlleleDepths must be a hash reference ";
        }
    }
    my $col = $args{column} || $args{sample_to_columns}->{$args{sample}};
    my %var_format = getVariantFormatFields($args{line});
    my @ad = ();
    if (defined $var_format{AD}){
        my $ad = getSampleGenotypeField
            (
                    line   => $args{line},
                    field  => 'AD',
                    column => $col,
            );
        if (defined $ad){
            @ad = split(",", $ad);
        }
    }elsif(defined $var_format{RO} and defined $var_format{AO}){ 
#freebayes observation counts
        
        my $ao = getSampleGenotypeField
            (
                    line   => $args{line},
                    field  => 'AO',
                    column => $col,
            );
        my $ro = getSampleGenotypeField
            (
                    line   => $args{line},
                    field  => 'RO',
                    column => $col,
            );
        if (defined $ro and defined $ao){
            push @ad, $ro;
            push @ad, split(",", $ao) ;
        }
    }else{
       carp "Cannot calculate allele depth without either AD or AO and RO FORMAT fields!\n"; 
    }
    return @ad;
}


=item B<countGenotypes>

Returns a hash of genotypes found in samples for a given line with the values being the number of each genotype encountered.

Arguments:

=over 16

=item line

Array reference to a split line to be passed as the first argument. Required.

=item minGQ

Minimum genotype quality. If the genotype quality (GQ) field for a sample is less than this value then a no call ("./.") will be assigned to that sample. If the GQ field is absent the function will carp annoyingly and return no calls for samples.

=item samples

A reference to an array of samples to count genotypes for. If used in conjunction with "sample_to_columns" argument the values are assumed to be sample names. Otherwise they are assumed to be column numbers. If this option is not used then genotypes for ALL samples in a given line will be counted.

=item sample_to_columns

A reference to a hash of sample names to 0-based column numbers as generated by the "getSamples" method. Use this to use sample names rather than column numbers with "samples" option.

=item genotypes

A reference to an array of genotypes to count. Only these genotypes will be counted and included in the hash returned by this function

=back

 
 my %geno_counts = VcfReader::countGenotypes
                   (
                        line => \@line,
                   );

 my %geno_counts = VcfReader::countGenotypes
                   (
                        line => \@line,
                        minGQ => 20,
                   );

 my %geno_counts = VcfReader::countGenotypes
                   (
                        line => \@line,
                        genotypes => ['0/1', '1/1', '0/2', '1/2', '2/2'],
                   );

 my %geno_counts = VcfReader::countGenotypes
                   (
                        line => \@line,
                        samples => [sampleA, sampleB, sampleC],
                   );


=cut
sub countGenotypes{
    my (%args) = @_;
    croak "\"line\" argument must be passed to countGenotypes " if not defined $args{line};
    carp "WARNING Both multiple and sample arguments supplied to countGenotypes method - only multiple argument will be used " if (defined $args{multiple} and defined $args{sample});
    if (defined $args{sample_to_columns}){
        if (ref $args{sample_to_columns} ne 'HASH'){
            croak "\"sample_to_columns\" argument passed to countGenotypes must be a hash reference ";
        }
    #}elsif(defined $args{sample} or $args{multiple}){
    #    croak "\"multiple\" and \"sample\" arguments can only be used in conjunction with \"sample_to_columns\" option for getSampleCall method ";
    }
    my %genotypes = ();
    if(defined $args{samples}){
        croak "samples argument must be an array reference " if ref $args{samples} ne 'ARRAY';
        foreach my $sample (@{$args{samples}}){
            my $col = $sample;
            if (defined $args{sample_to_columns}){
                croak "Sample \"$sample\" does not exist in samples_to_columns hash passed to countGenotypes " 
                    if not exists $args{sample_to_columns}->{$sample};
                $col = $args{sample_to_columns}->{$sample};
            }
            if (defined $args{minGQ}){
                my $call = getSampleCall(line => $args{line}, column => $col, minGQ => $args{minGQ});
                $genotypes{$call}++;
            }else{
                my $call = getSampleCall(line => $args{line}, column => $col,);
                $genotypes{$call}++;
            }
        }
    }else{
        foreach my $col (9..$#{$args{line}}){
            if (defined $args{minGQ}){
                my $call = getSampleCall(line => $args{line}, column => $col, minGQ => $args{minGQ});
                $genotypes{$call}++;
            }else{
                my $call = getSampleCall(line => $args{line}, column => $col);
                $genotypes{$call}++;
            }
        }
    }
    if (defined $args{genotypes}){
        my %user_gts = ();
        if (ref $args{genotypes} eq 'ARRAY'){
            foreach my $gt (@{$args{genotypes}}){
                if (exists $genotypes{$gt}){
                    $user_gts{$gt} =  $genotypes{$gt};
                }else{
                    $user_gts{$gt} = 0;
                }
            }
            return %user_gts;
        }else{
            if (exists $genotypes{$args{genotypes}}){
                return $genotypes{$args{genotypes}};
            }else{
                return 0;
            }
        }
    }
        
    return %genotypes;
}


=item B<countAlleles>

Returns a hash where keys are alleles and values are the counts for each allele for a given line. The counts are per chromosome assuming diploidy, such that a homozygous call will count as two copies of an allele and het calls will count as one of each allele. WARNING - this method will obviously NOT BE ACCURATE for sex chromosomes.

Arguments:

=over 16

=item line

Array reference to a split line to be passed as the first argument. Required.

=item minGQ

Minimum genotype quality. If the genotype quality (GQ) field for a sample is less than this value then their alleles will not be counted.

=item samples

A reference to an array of samples to retrieve genotypes from. If used in conjunction with "sample_to_columns" argument the values are assumed to be sample names. Otherwise they are assumed to be column numbers. If this option is not used then alleles for all samples in a given line will be counted.

=item sample_to_columns

A reference to a hash of sample names to 0-based column numbers as generated by the "getSamples" method. Use this to use sample names rather than column numbers with "samples" option.

=back


 my %allele_counts = VcfReader::countAlleles
                     (
                        line => \@line,
                     );

 my %allele_counts = VcfReader::countAlleles
                     (
                        line => \@line,
                        minGQ => 20,
                     );

 my %allele_counts = VcfReader::countAlleles
                     (
                        line => \@line,
                        minGQ => 20,
                        samples => [sampleA, sampleB],
                     );

=cut
sub countAlleles{
    #%allele_counts = $obj->countGenotypes(); 
    #returns count for all samples and all genotypes
    #%allele_counts = $obj->countGenotypes(samples=>["sample1","sample2"])
    #$count = $obj->countGenotypes(samples=>["sample1","sample2"], genotypes => '0/1');
    my (%args) = @_;
    croak "\"line\" argument must be passed to countAlleles " if not defined $args{line};
    croak "line argument must be an array reference " if ref $args{line} ne 'ARRAY';
    if (defined $args{sample_to_columns}){
        if (ref $args{sample_to_columns} ne 'HASH'){
            croak "\"sample_to_columns\" argument passed to countAlleles must be a hash reference ";
        }
    }
    my %counts; 
    my $inf_ac = getVariantInfoField($args{line}, 'AC');
    my $inf_an = getVariantInfoField($args{line}, 'AN');
    if (not defined $args{samples}){
        if ( (not $args{minGQ} and defined $inf_ac and defined $inf_an )
             or $#{$args{line}} < 9 #no samples in VCF
        ){
            my @ac = split(",", getVariantInfoField($args{line}, 'AC'));
            unshift @ac,  getVariantInfoField($args{line}, 'AN') - sum(@ac);
            for (my $i = 0; $i < @ac; $i++){
                $counts{$i} = $ac[$i];
            }
            return %counts;
        }
    }
    my @alleles = readAlleles(line => $args{line});
    for (my $i = 0; $i < @alleles; $i++){
        $counts{$i} = 0;
    }
    if(defined $args{samples}){
        croak "samples argument must be an array reference " if ref $args{samples} ne 'ARRAY';
        foreach my $sample (@{$args{samples}}){
            my $call;
            my $column = $sample;
            if (defined $args{sample_to_columns}){
                croak "Sample \"$sample\" does not exist in samples_to_columns hash passed to countGenotypes " 
                    if not exists $args{sample_to_columns}->{$sample};
                $column = $args{sample_to_columns}->{$sample};
            }
            if (defined $args{minGQ}){
                $call = getSampleCall(line => $args{line}, column=>$column, minGQ => $args{minGQ});
            }else{
                $call= getSampleCall(line => $args{line}, column=>$column);
            }
            my @ca = split(/[\/\|]/, $call);
            @ca = grep {$_ ne '.'} @ca;
            map {$counts{$_}++} @ca;
        }
    }else{
        foreach my $column (9..$#{$args{line}}){
            my $call;
            if (defined $args{minGQ}){
                $call = getSampleCall(line => $args{line}, column=>$column, minGQ => $args{minGQ});
            }else{
                $call= getSampleCall(line => $args{line}, column=>$column);
            }
            my @ca = split(/[\/\|]/, $call);
            @ca = grep {$_ ne '.'} @ca;
            map {$counts{$_}++} @ca;
        }
    }
    return %counts;
}


sub _getGenotype{
    my ($line, $col, $min_gq) = @_;
    $col = 9 if not $col;
    $min_gq = 0 if not $min_gq;
    my $mvar = getSampleVariant
    ( 
        $line,
        $col,
    );
    if ($min_gq > 0){
        my $gq = getSampleGenotypeField
        (
            line => $line, 
            column=>$col,
            field=>'GQ',
        );
        if (not defined $gq){
            #no GQ field - return no call (the above generally means that the call is './.' anyway)
            return './.';
        }
        if ($gq eq '.'){
            return './.';
        }
        if ($gq < $min_gq){
            return './.';
        }
    }
    my $call = getSampleGenotypeField
    (
        line => $line, 
        column => $col, 
        field=>'GT'
    ); 
    return $call;
}




=item B<getAllPossibleGenotypeCodes>

Returns a list of possible genotype codes for a give line given the number of ALT alleles. For example, when only one ALT allele is present an array containing '0/0', '0/1' and '1/1' will be returned. Requires an array reference to a split line as the only argument. 

 my @gt_codes = VcfReader::getAllPossibleGenotypeCodes(\@line);

=cut
sub getAllPossibleGenotypeCodes{
#returns genotype codes - e.g. 0/0, 0/1, 1/1
    my ($line) = @_;
    my @alleles = readAlleles(line => $line);
    my @combinations = ();
    for (my $n = 0; $n < @alleles; $n++){
        for (my $m = 0; $m <= $n; $m++){
            push (@combinations, "$m/$n");
        }
    }
    return @combinations if defined wantarray;
    carp "getAllPossibleGenotypes called in void context ";
}

=item B<getAllPossibleGenotypes>

Does the same as "getAllPossibleGenotypeCodes" but returns the actual values for REF and ALT alleles - e.g. "A/A", "A/T", "T/T".

 my @gts = VcfReader::getAllPossibleGenotypes(\@line);

=cut
sub getAllPossibleGenotypes{
#returns actual allele genotypes - e.g. A/A, A/T, T/T
    my ($line) = @_;
    my @alleles = readAlleles(line => $line);
    my @combinations = ();
    for (my $n = 0; $n < @alleles; $n++){
        for (my $m = 0; $m <= $n; $m++){
            push (@combinations, "$alleles[$m]/$alleles[$n]");
        }
    }
    return @combinations if defined wantarray;
    carp "getAllPossibleGenotypes called in void context ";
}

=item B<replaceVariantField>

Returns a split line with a variant field replaced with a given value. Requires three arguments: an array reference to a split line, the name of the column to replace and the value for the replacement.

 my $modified_line = VcfReader::replaceVariantField(\@line, 'ID', 'rs01234567');
 print join("\t", @$modified_line) ."\n";

=cut
sub replaceVariantField{
    my ($line, $field, $replacement) = @_;
    $field =~ s/^#+//;
    croak "Invalid field ($field) passed to replaceVariantField method " if not exists VCF_FIELDS->{$field};
    splice(@$line, VCF_FIELDS->{$field}, 1, $replacement);
    return $line if defined wantarray;
    #return join("\t", @$line) if defined wantarray;
    carp "replaceVariantField called in void context ";
}

=item B<minimizeAlleles>

Reduces the REF and ALT allele fields to their simplest possible reprensentations, returning a hash with each variant allele code as a key to an anonymous hash of CHROM, POS, REF, ALT, ORIGINAL_POS, ORIGNAL_REF and ORIGINAL_ALT fields. REF and ALT fields are trimmed to their shortest possible representations while retaining the information required. In this way, different representations of the same variants can be identified between different VCFs (e.g. if different variant callers were used). Requires an array reference to a split line as the only argument. 

 my %minimised = VcfReader::minimizeAlleles(\@line);
 foreach my $allele (sort { $a<=>$b }  keys %minimised){
    print "For alt allele $allele simplest REF is $minimised{REF}\n";
    print "For alt allele $allele simplest ALT is $minimised{ALT}\n";
    print "For alt allele $allele variant  POS is $minimised{POS}\n";
    print "For alt allele $allele simplest REF is $minimised{REF}\n";
 }


=cut
sub minimizeAlleles{
    #reduce alleles to their simplest representation
    #so that multiallelic variants can be represented 
    #in their most basic form
    #e.g. (from http://www.cureffi.org/2014/04/24/converting-genetic-variants-to-their-minimal-representation/)
    #1  1001    .   CTCC    CCC,C,CCCC 
    #becomes
    #1  1001   CTCC    CCC →   1001    CT  C
    #1001   CTCC    C   →   1001    CTCC    C
    #1001   CTCC    CCCC    →   1002    T   C
    #
    my ($line) = @_;
    my %min_alleles = ();#key is allele number, each entry is anon hash of CHROM, REF, POS, ALT
    my @al =  readAlleles(line => $line);
    for (my $i = 1; $i < @al; $i++){
        my ($pos, $ref, $alt) = reduceRefAlt($line->[VCF_FIELDS->{POS}], $al[0], $al[$i]);
        $min_alleles{$i} = {
            CHROM           => $line->[VCF_FIELDS->{CHROM}],
            POS             => $pos,
            REF             => $ref,
            ALT             => $alt,
            ORIGINAL_POS    => $line->[VCF_FIELDS->{POS}],
            ORIGINAL_REF    => $line->[VCF_FIELDS->{REF}],
            ORIGINAL_ALT    => $al[$i],
            ALT_INDEX        => $i,
        };
    }
    return %min_alleles if defined wantarray;
    carp "minimizeAlleles called in void context ";
}

=item B<reduceRefAlt>

For a given coordinate, REF allele and ALT allele this function returns the simplest representation of these features.

 my ($reduced_pos, $reduced_ref, $reduced_alt) = VcfReader::reduceRefAlt($position, $ref_allele, $alt_allele);

=cut
sub reduceRefAlt{
    #reduce a single ref/alt pair to their simplest representation
    my ($pos, $ref, $alt) = @_;
    if (length($ref) > 1 and length($alt) > 1){
        #can only reduce if both REF and ALT are longer than 1
        my @r = split('', $ref);
        my @al = split('', $alt);
        while ($r[-1] eq $al[-1] and @r > 1 and @al > 1){
            #remove identical suffixes
            pop @r;
            pop @al;
        }
        while ($r[0] eq $al[0] and @r > 1 and @al > 1){
            #remove identical prefixes
            #increment position accordingly
            shift @r;
            shift @al;
            $pos++;
        }
        $ref = join('', @r);
        $alt = join('', @al);
    }
    return ($pos, $ref, $alt);
}


=item B<getSpan>

For a given line this function returns the 5' most position altered. Requires an array reference to a split line as the only argument.

 my $span = VcfReader::getSpan(\@line);

=cut
sub getSpan{
    my ($line) = @_;
    my $end;
    if ($line->[VCF_FIELDS->{ALT}] =~ /^</){#try to deal with CNVs
        if ($end = getVariantInfoField($line, 'END')){
        }else{
            $end = $line->[VCF_FIELDS->{POS}];
        }
    }else{
        $end = $line->[VCF_FIELDS->{POS}] + length($line->[VCF_FIELDS->{REF}]) -1;
    }
    return $end;
}

=item B<variantsHaveMatchingAlleles>

For two lines check whether they contain any matching variant alleles. Both variants have their alleles reduced to their simplest possible representations and then alleles are checked to see if CHROM, POS, REF and ALT values are the same for ANY of the alleles represented between the two lines.

Requires two array references, one for each split line to compare. 

 if (VcfReader::variantsHaveMatchingAlleles(\@line1, \@line2){
     print "Lines have matching alleles!";
 }

=cut

sub variantsHaveMatchingAlleles{
    my ($line1, $line2) = @_;
    if ($line1->[VCF_FIELDS->{CHROM}] ne $line2->[VCF_FIELDS->{CHROM}]){
        return 0;
    }
    my %min1 = minimizeAlleles($line1);
    my %min2 = minimizeAlleles($line2);
    foreach my $allele1 (keys %min1){
        foreach my $allele2 (keys %min2){
            next if $min1{$allele1}->{POS} ne $min2{$allele2}->{POS};
            next if $min1{$allele1}->{REF} ne $min2{$allele2}->{REF};
            next if $min1{$allele1}->{ALT} ne $min2{$allele2}->{ALT};
            return 1;#we return 1 if ANY allele matches
        }
    }
    return 0;
}

=item B<calculateGenotypeGindex>

For a given genotype (e.g. "0/1") as the only argument, the index of the position of any occurences of the genotype in a FORMAT/INFO field with one entry per genotype ( i.e. "Number=G"). Phased genotypes (e.g. "1|0") will be converted to unphased (e.g. "0/1") for the purpose of this method.

 my $idx = VcfReader::calculateGenotypeGindex("1/1");
 
=cut


sub calculateGenotypeGindex{
    my ($gt) = @_;
    if ($gt !~ /^\d+[\/\|]\d+$/){
        carp "calculateGenotypeGindexes method only works on biallelic ".
             "genotypes. Genotype '$gt' is invalid.\n";
    }
    my @alts = sort {$a <=> $b} split(/[\/\|]/, $gt); 
    return ($alts[1]*($alts[1]+1)/2)+$alts[0];
}

=item B<calculateGenotypeFromGindex>

For a given index of an entry per genotype field ( i.e. "Number=G"), returns the genotype call represented by it. So, passing 0 to this function returns "0/0", passing 1 returns "0/1" and so on.

 my $gt = VcfReader::calculateGenotypeFromGindex(2);
 
=cut

sub calculateGenotypeFromGindex{
    my $n = shift;
    my $m = 0;
    for (my $i = 0; $i <= $n; $i++){
        for (my $j = 0; $j <= $i; $j++){
            if ($m == $n){
                return "$j/$i";
            }
            $m++;
        }
    }
}


=item B<calculateAlleleGindexes>

For a given line as the first argument, and allele index (0 for ref, 1 for first ALT, 2 for second ALT etc.) as the second argument, an array of indexes will be returned indicating the position of any occurences of the allele in a FORMAT/INFO field with one entry per genotype (i.e. "Number=G"). 

 my @idxs = VcfReader::calculateAlleleGindexes(\@line, 1); 
 
=cut


sub calculateAlleleGindexes{
    my ($line, $allele) = @_;
    my @alts = readAlleles(line => $line);
    my @idx = (); 
    for (my $y = 0; $y < @alts; $y++){
        my ($i, $j) = sort {$a <=>$b} ($allele, $y); 
        push @idx , ($j*($j+1)/2)+$i;
    }
    return @idx;
}

=item B<calculateOtherAlleleGindexes>

For a given line as the first argument, and allele index (0 for ref, 1 for first ALT, 2 for second ALT etc.) as the second argument, an array of indexes will be returned indicating the position of genotypes that DO NOT include the given allele in a FORMAT/INFO field with one entry per genotype (i.e. "Number=G"). That is, it returns all genotype indexes not given by the calculateAlleleGindexes method.

 my @idxs = VcfReader::calculateOtherAlleleGindexes(\@line, 1); 
 
=cut


sub calculateOtherAlleleGindexes{
    my ($line, $allele) = @_;
    my @alts = readAlleles(line => $line);
    my @others = grep { $_ != $allele } 0 .. $#alts;
    my @idx = (); 
    for (my $i = 0; $i < @others; $i++){
        for (my $j = 0; $j <= $i; $j++){
            push @idx , ($others[$i]*($others[$i]+1)/2)+$others[$j];
        }
    }
    return @idx;
}



=head2 String Conversion Utilities

=item B<convertTextForInfo>

Takes a string it's only argument and returns a new string with characters not compatible with VCF format converted to characters that will not break VCF format. Specifically, the following characters are replaced as indicated:

    '|' with '::'
    ';' with '^'
    ',' with '`'
    any whitespace with '_'

 $compatible_string = VcfReader::convertTextForInfo($some_string); 
 my $modified_line = VcfReader::addVariantInfoField
    (
        line  =>\@line, 
        id    => 'SOME_FIELD', 
        value => $compatible_string, 
    );

=cut 

sub convertTextForInfo{
    #replace characters not compatible with VCF
    #format for annotations
    my ($string) = @_;
    $string =~ s/\|/::/g;
    $string =~ tr/;, \t\n\r/^`____/;
    return $string;
}


=item B<reconvertTextForInfo>

Takes a string it's only argument and returns a new string reversing the substitutions made by the 'convertTextForInfo' method. One unfortunate shortcoming is that underscores will be converted to spaces regardless of whether that is desired or not.

 my $string = VcfReader::getVariantInfoField(\@line, 'SOME_FIELD');
 $conv_string = VcfReader::reconvertTextForInfo($string); 

=cut 

sub reconvertTextForInfo{
    #replace characters not compatible with VCF
    #format for annotations
    my ($string) = @_;
    $string =~ tr/^`_/;, /;
    $string =~ s/::/\|/g;
    return $string;
}

=back 

=head2 Sort Utilities


=over 12

=item sortVcf

Creates a coordinate sorted VCF file from a given VCF file. Contig orders can be explicitly given using the 'contig_order' argument. Otherwise, the contig order will be derived from the header if possible and failing that contigs will be ordered numerically, followed by 'X', 'Y', 'MT' and then ascibetically. This method will also remove duplicate lines.

Arguments

=over 16

=item vcf

filename or filehandle of input VCF file to sort. Required.

=item output

filename or filehandle for output. If this argument is not provided data will be sent to STDOUT.

=item contig_order 

reference to a hash with contig names as keys and their relative order as values. If provided without 'dict' argument contig headers will be replaced but without information such as length or assembly.

=item dict

reference to an array of replacement contig ID header lines in the format "##contig=<ID=1,[other fields]>" Use this to replace the contig headers in your VCF in the given order. 

=item tmp_dir

temporary directory to use (only used if Sort::External is installed).

=back

 VcfReader::sortVcf(vcf => 'unsorted_file.vcf', output => 'sorted_file.vcf');
 
 my %contigs = (contig_1 => 0, contig_2 => 1,  contig_3 => 2);
 my @dict = qw  (   ##contig=<ID=contig_1,length=249250621>  
                    ##contig=<ID=contig_2,length=243199373=>
                    ##contig=<ID=contig_3,length=198022430=>
                );
 VcfReader::sortVcf
    (
        vcf => 'unsorted_file.vcf', 
        output => 'sorted_file.vcf', 
        contig_order => \%contigs,
        dict => \@dict,
    );

=cut
sub sortVcf{
#creates a new vcf sorted in coordinate order
#returns filename of new sorted file
    my (%args) = @_;
    croak "\"vcf\" argument is required for sortVcf function "  if not $args{vcf};
    my %contigs = ();
    my $do_not_replace_header;
    my $previous = '';
    my %temp_dict = ();
    my @dict = ();
    my $add_ids = 0;
    my $i = 0;
    my ($head, $first, $FH) = VcfReader::getHeaderAndFirstVariant($args{vcf});
    #let's us work on a stream
    if (not $args{contig_order}){
        %contigs = getContigOrderFromHeader(header => $head);
        $do_not_replace_header++ if %contigs;
    }else{
        if (ref $args{contig_order} ne 'HASH'){
            croak "contig_order argument passed to sortVcf method must be a hash reference ";
        }
        %contigs = %{$args{contig_order}};
    }
    if ($args{dict}){
        if (ref $args{dict} ne 'ARRAY'){
            croak "dict argument passed to sortVcf method must be an array reference ";
        }
        @dict = @{$args{dict}};
    }elsif (%contigs and not $do_not_replace_header){
        foreach my $k (sort {$contigs{$a} <=> $contigs{$b}} keys %contigs){
            push @dict, "##contig=<ID=$k>";
        }
    }

    my $SORTOUT;
    if (exists $args{output}){
        if (openhandle($args{output})){
            $SORTOUT = $args{output};
        }else{
            open ($SORTOUT,  ">$args{output}") or croak "Can't open file $args{output} for output of sortVcf: $! ";
            print STDERR "Sorting $args{vcf} to $args{output}.\n"; 
        }
    }else{
        $SORTOUT = \*STDOUT;
    }
    eval "use Sort::External; 1" or carp "The Sort::External module was not found - will attempt to sort in memory. For huge files it is recommended to install Sort::External via CPAN.\n";
    if ($@){#no Sort::External , sort in memory
        print STDERR "Reading variants into memory...\n";
        my @sort = ();
        my ($l, $c) = _lineToVcfSort($first, \%contigs);
        push @sort, "$l\n";#chomped, but not chomping other lines
        if (not @dict){
            $temp_dict{$c} = undef;
        }
        while (my $line =  <$FH>){
            next if $line =~ /^#/;
            my ($l, $c) = _lineToVcfSort($line);
            push @sort, $l;
            if (not @dict){
                $temp_dict{$c} = undef;
            }
        }
        close $FH;
        if (not @dict){
            @dict = map {"##contig=<ID=$_>"} sort byContigs keys %temp_dict ;
        }
        my @out_head = ();
        if ($do_not_replace_header){
            @out_head = @$head;
        }else{
            @out_head = _replaceHeaderContigs($head, \@dict) ;
        }
        print STDERR "Performing sort...\n";

        if (%contigs){
            @sort = sort @sort;
        }else{
            @sort = sort {
                (my $a_chrom = substr($a, 0, 25)) =~ s/\s+$//;
                (my $b_chrom = substr($b, 0, 25)) =~ s/\s+$//;
                (my $a_pos = substr($a, 25, 4)) ;
                (my $b_pos = substr($b, 25, 4)) ;
                _byContigsManual($a_chrom, $b_chrom) ||
                $a_pos cmp $b_pos;
            } @sort;
        }
        print STDERR "Printing output...";
        
        print $SORTOUT join("\n", @out_head) ."\n";
        foreach my $s (@sort){
            my $var = '';
            if (%contigs){
                $var = substr($s, 8);
            }else{
                $var = substr($s, 29);
            }
            print $SORTOUT $var if $var ne $previous;
            $var = $previous;
        }
    }else{
        my %sortex_args = (mem_threshold => 1024**2 * 16);
        if ($args{tmp_dir}){
            $sortex_args{working_dir} = $args{tmp_dir};
        }
        if (not %contigs){
            my $vcfsort = 
                sub {
                    (my $a_chrom = substr($Sort::External::a, 0, 25)) =~ s/\s+$//;
                    (my $b_chrom = substr($Sort::External::b, 0, 25)) =~ s/\s+$//;
                    (my $a_pos = substr($Sort::External::a, 25, 4)) ;
                    (my $b_pos = substr($Sort::External::b, 25, 4)) ;
                    _byContigsManual($a_chrom, $b_chrom) ||
                    $a_pos cmp $b_pos;
                };

            $sortex_args{sortsub} = $vcfsort;
        }
        my $sortex = Sort::External->new(%sortex_args);
        my @feeds = ();
        my ($l, $c) = _lineToVcfSort($first, \%contigs);
        push @feeds, "$l\n";#chomped, but not chomping other lines
        if (not @dict){
            $temp_dict{$c} = undef;
        }
        my $n = 1;
        while (my $line = <$FH>){
            next if ($line =~ /^#/);
            $n++;
            my ($l, $c) = _lineToVcfSort($line, \%contigs);
            push @feeds, $l;
            if (not @dict){
                $temp_dict{$c} = undef;
            }
            if (@feeds > 49999){
                $sortex->feed(@feeds);
                @feeds = ();
                print STDERR "\rFed $n variants to sort...";
            }
        }
        close $FH;
        if (not @dict){
            @dict = map {"##contig=<ID=$_>"} sort byContigs keys %temp_dict ;
        }
        $sortex->feed(@feeds) if @feeds;
        print STDERR "\nFed $n variants to sort...\n";
        my $total = $n;
        print STDERR "Finishing sort and writing output...\n";
        $sortex->finish; 
        $n = 0;
        my @out_head = ();
        if ($do_not_replace_header){
            @out_head = @$head;
        }else{
            @out_head = _replaceHeaderContigs($head, \@dict) ;
        }
        print $SORTOUT join("\n", @out_head) ."\n";
        while ( defined( $_ = $sortex->fetch ) ) {
            my $var = '';
            if (%contigs){
                $var = substr($_, 8);
            }else{
                $var = substr($_, 29);
            }
            print $SORTOUT $var if $var ne $previous;
            $var = $previous;
            $n++;
            if (not $n % 5000){
                print STDERR "\rPrinted $n variants to output...";
            }
        }
    }
    if (exists $args{output}){
        close $SORTOUT or croak "Couldn't finish writing to sort output file $args{output}: $!\n" ;
    }
    print STDERR "\nDone.\n";
    return $args{output} if defined wantarray
}


sub _lineToVcfSort{
    my $line = shift;
    my $contigs = shift;
    my @split = split("\t", $line, 3);
    my $chrom = $split[VCF_FIELDS->{CHROM}];
    my $pos = $split[VCF_FIELDS->{POS}];
    my $s_chrom; 
    if ($contigs and %$contigs){
        if (not exists $contigs->{$chrom}){
            carp "WARNING: Contig '$chrom' is not present in user ".
                 "provided contig order ";
            #put unexpected contigs to end of VCF
            $contigs->{$chrom} = scalar keys %{$contigs};
        }
        $s_chrom = pack("N", $contigs->{$chrom}); 
    }else{
        $s_chrom = sprintf("%-25s", $chrom); 
    }
    my $p_pos = pack("N", $pos); 
    return ("$s_chrom$p_pos$line", $chrom);
}

sub _replaceHeaderContigs{
    my ($head, $dict) = @_;
    if (ref $head ne 'ARRAY' or ref $dict ne 'ARRAY'){
        croak "arguments passed to _replaceHeaderContigs must be array references "
    }
    my @new_head = ();
    my $replaced;
    foreach my $h (@$head){
        if ($h =~ /^##contig=</){
            if (not $replaced){
                push @new_head, @$dict;
                $replaced++;
            }
        }else{
            push @new_head, $h;
        }
    }
    if (not $replaced){
        splice(@new_head, -1, 0, @$dict)
    }
    return @new_head;
}



=item B<sortVariants>

Takes as its first argument a reference to an array of pre-split VCF line array references and an optional second argument of a reference to a hash of contigs with the values being their relative order (i.e. 'chr1' => 0, 'chr2' => 1). If used without a second argument contigs will be ordered numerically, then X, Y and MT and any other contigs will be ordered ascibetically. Returns an array of contig and coordinate sorted pre-split VCF lines.

The example below is redundant (use SortVcf instead) but gives you an idea how to use this function.

 while (<VCF>){
    chomp;
    next if /^#/;
    my @line = split(/\t/);
    push @variants, \@line;
 }
 my @sorted_variants = VcfReader::sortVariants(\@variants);

 my %contigs = (contig_1 => 0, contig_2 => 1,  contig_3 => 2);
 my @custom_sorted_variants = VcfReader::sortVariants(\@variants, \%contigs);

=cut
sub sortVariants{
#sort a list of vcf lines
    my ($list, $contig_order) = @_;
    croak "sortVariants required an array reference as an argument " if (ref $list ne 'ARRAY');
    if ($contig_order){
        croak "second argument passed to sortVariants must be a hash reference of contigs and their orders " if (ref $contig_order ne 'HASH');
    }
    my %contigs = ();
    my $add_ids = 0;
    my $i = 0;
    if ($contig_order){
        %contigs = %{$contig_order};
    }else{
        my %temp = ();
        foreach my $l (@$list){
            $temp{$l->[VCF_FIELDS->{CHROM}]}++;
        }
        my $n = 0;
        %contigs = map {$_ => $n++} sort byContigs(keys %temp);
    }
    my @sort = sort {
        $contigs{$a->[VCF_FIELDS->{CHROM}]} <=> $contigs{$b->[VCF_FIELDS->{CHROM}]} ||
        $a->[VCF_FIELDS->{POS}] <=> $b->[VCF_FIELDS->{POS}]
    } @$list;
    return @sort if defined wantarray;
    carp "sortVariants method called in void context ";
}


=item B<sortByPos>

Sort method to sort variants by position only (useful if you have an array of variants from a single contig).

 @var = VcfReader::sortByPos(\@var);

=cut

sub sortByPos{
    my $vars = shift;
    return sort { $a->[VCF_FIELDS->{POS}] <=> $b->[VCF_FIELDS->{POS}] } @$vars;
}
    

=item B<byContigs>

Sort method to sort contigs on a generic order. Contigs will be ordered numerically, then X, Y and MT and any other contigs will be ordered ascibetically.

 my @contigs = sort VcfReader::byContigs @contigs;

=cut
sub byContigs{
    $a =~ s/^chr//;
    $b =~ s/^chr//;
    if ($a =~ /^\d+$/){
        if ($b =~ /^\d+$/){
            return $a <=> $b;
        }else{
            return -1;
        }
    }elsif ($b =~ /^\d+$/){
        return 1;
    }elsif ($a =~ /^[XY]$/){
        if ($b =~ /^[XY]$/){
            return $a cmp $b;
        }else{
            return -1;
        }
    }elsif ($b =~ /^[XY]$/){
        return 1;
    }elsif ($a =~ /^MT*$/){
        return $b cmp $a;
    }elsif ($b =~ /^MT*$/){
        return 1;
    }else{
        return $a cmp $b;
    }
}

#below is the same method as above
#but allowing for manual specification of $a and $b
#for use within more complex sort subs 
sub _byContigsManual{
    my ($sort_a, $sort_b) = @_;
    $sort_a =~ s/^chr//;
    $sort_b =~ s/^chr//;
    if ($sort_a =~ /^\d+$/){
        if ($sort_b =~ /^\d+$/){
            return $sort_a <=> $sort_b;
        }else{
            return -1;
        }
    }elsif ($sort_b =~ /^\d+$/){
        return 1;
    }elsif ($sort_a =~ /^[XY]$/){
        if ($sort_b =~ /^[XY]$/){
            return $sort_a cmp $sort_b;
        }else{
            return -1;
        }
    }elsif ($sort_b =~ /^[XY]$/){
        return 1;
    }elsif ($sort_a =~ /^MT*$/){
        return $sort_b cmp $sort_a;
    }elsif ($sort_b =~ /^MT*$/){
        return 1;
    }else{
        return $sort_a cmp $sort_b;
    }
}

=item B<by_first_last_line>

Sorts an array of arrays of variants (each being an array reference to a split line) on the coordinates of each array's first and last lines. This obtuse sounding method is designed for sorting batches of variants that were processed from a pre-sorted file in parallel. So, if you have processed batches of 1000 variants in parallel using forks you can use this method to quickly restore these batches to their previous order. The first two arguments are the features to sort and the third argument must be a reference to a hash of contigs and their relative orders such as that generated by the 'getContigOrder' function.
      
    my @sorted_batches = sort { VcfReader::by_first_last_line($a, $b, \%contig_order) } @batches;

=cut
sub by_first_last_line{
    #sorts batches of variants on the coordinates of their first and last lines
    #use for sorting batches of variants that were processed from a pre-sorted file
    #usage - 
    #       my @sorted = sort { VcfReader::by_first_last_line($a, $b, \%contig_order) } @batches;
    #where \%contig_order has been generated using VcfReader::getContigOrder
    my ($aref, $bref, $contigs) = @_;
    if (ref $aref ne 'ARRAY' or ref $bref ne 'ARRAY'){
        croak "First 2 arguments passed to by_first_last_line must be ARRAY references ";
    }
    my $aref_first_chrom = getVariantField( $aref->[0],  "CHROM", );
    my $aref_first_pos   = getVariantField( $aref->[0],  "POS", );
    my $aref_last_chrom  = getVariantField( $aref->[-1], "CHROM", );
    my $aref_last_pos    = getVariantField( $aref->[-1], "POS", );
    my $bref_first_chrom = getVariantField( $bref->[0],  "CHROM", );
    my $bref_first_pos   = getVariantField( $bref->[0],  "POS", );
    my $bref_last_chrom  = getVariantField( $bref->[-1], "CHROM", );
    my $bref_last_pos    = getVariantField( $bref->[-1], "POS", );

    if ( $contigs->{$aref_first_chrom} > $contigs->{$bref_last_chrom} ) {
        return 1;
    }
    elsif ( $contigs->{$aref_last_chrom} < $contigs->{$bref_first_chrom} ) {
        return -1;
    }
    elsif ( $contigs->{$aref_last_chrom} > $contigs->{$bref_last_chrom} ) {
        return 1;
    }
    elsif ( $contigs->{$aref_first_chrom} > $contigs->{$bref_first_chrom} ) {
        return 1;
    }
    elsif ( $contigs->{$aref_last_chrom} < $contigs->{$bref_last_chrom} ) {
        return -1;
    }
    elsif ( $contigs->{$aref_last_chrom} > $contigs->{$bref_last_chrom} ) {
        return 1;
    }
    elsif ( $aref_last_pos <= $bref_first_pos ) {
        return -1;
    }
    elsif ( $aref_first_pos >= $bref_last_pos ) {
        return 1;
    }
    return 0;
}



=back


=head2 Search Utilities


=over 12

=item B<getTabixIterator>

For a given VCF returns a tabix iterator object generated using Tabix.pm. The first argument must be the filename of a VCF and the optional second argument may be the name of the index if not the same as the VCF filename plus '.tbi'.

 my $iter = VcfReader::getTabixIterator('file.vcf.gz');
 my $i = $iter->query('chr1:10001-10002");
 while (my $line =  $iter->next ){
    #do something with line...
 }

=cut
sub getTabixIterator{
    my $vcf = shift;
    eval "use Bio::DB::HTS::Tabix; 1" or croak "Bio::DB::HTS::Tabix module is not installed - can't use getTabixIterator method ";
    return Bio::DB::HTS::Tabix->new(filename =>  $vcf);
}

=item B<getSearchArguments>

Returns a hash of arguments that can be used in searchByRegion or searchForPosition methods. Provides the file arguments so that only the arguments relating to the coordinates need to also be provided to those methods. 

While both searchByRegion and searchForPosition methods can genereate these values on the fly (e.g. create a tabix iterator or read the index file for an uncompressed VCF) the idea here is that if you have a script that repeatedly searches a file it is more efficient to generate an iterator/read the index only once and provide the necessary values for each search as arguments. This method is provided as a shortcut to retrieve the necessary arguments for a VCF.

Requires a VCF filename as the first argument. The optional second argument is a contig order index hash as obtained from the 'readIndex' function for use with uncompressed VCFs to save reading the index if already done. 
 
 my %search_arguments = VcfReader::getSearchArguments('file.vcf');
 my @hits = VcfReader::searchForPosition(%search_arguments, chrom => 1, pos => 1000000);

 my %index = VcfReader::readIndex('file.vcf');
 my %search_arguments = VcfReader::getSearchArguments('file.vcf', \%index);
 my @hits = VcfReader::searchForPosition(%search_arguments, chrom => 1, pos => 1000000);

=cut
sub getSearchArguments{
#returns hash of arguments and values for passing to searchForPosition method
#return hash of vcf, file_handle, index_handle and contig_order 
#for uncompressed files
#or tabix_iterator for bgzip compressed files
    my ($vcf, $contig_index) = @_;
    if ($vcf =~ /\.(b){0,1}gz$/){ 
        eval "use Bio::DB::HTS::Tabix; 1" 
            or croak "Bio::DB::HTS::Tabix module is not installed and VCF file $vcf appears to be (b)gzip compressed.  ".
            "  Please install Bio::DB::HTS::Tabix in order to search bgzip compressed VCFs.\n";
        my $index = "$vcf.tbi";
        if (not -e $index){
            print STDERR "Indexing $vcf with tabix...";
            indexVcf($vcf);
            croak "Tabix indexing failed? $index does not exist " if (not -e $index);
            print STDERR " Done.\n";
        }
        return (tabix_iterator => getTabixIterator($vcf));
    }else{
        my $FH = _openFileHandle($vcf);
        if ($contig_index){
            if (ref ($contig_index) ne 'HASH'){
                croak "second argument passed to getSearchArguments method must be a hash reference to a contig index ";
            }
        }else{
            my $index = "$vcf.vridx" ;
            if (not -e $index){
                print STDERR "$index does not exist - indexing $vcf...\n";
                indexVcf($vcf);
                croak "Indexing failed? $index does not exist " if (not -e $index);
                print STDERR " Done.\n";
            }
            my %contig_order  = readIndex($vcf);
            $contig_index = \%contig_order;
        }
        return (file_handle => $FH, contig_order => $contig_index);
    }
}
=item B<searchByRegion>

Searches a VCF for variants that lie within a given genomic region. Runs the appropriate search method depending on file extension - that is if a file has a '.gz' extension bgzip compression is assumed, otherwise uncompressed data is expected. Returns an array of variants if any are found.

Arguments

=over 16

=item vcf

File name of VCF file to search. This argument, 'file_handle' or 'tabix_iterator' argument is required.

=item file_handle

A file handle for the VCF to search. Only for uncompressed VCFs. Can be used instead of or in addition to 'vcf' argument. However, if used without 'vcf' argument the 'contig_order' argument is required in order to give index information.

=item contig_order

Contig order index hash as obtained from the 'readIndex' function. For use with uncompressed VCFs only. If not provided the index will be read, assuming the 'vcf' argument has been used to specify the filename.

=item tabix_iterator

A tabix iterator object for a bgzip compressed VCF. Can be used instead of or with 'vcf' argument. Will be created if not provided.

=item chrom

Name of chromosome to search. Required.

=item start

Start coordinate of region to search. Required.

=item end

End coordinate of region to search. Required.

=back 


 my @hits = VcfReader::searchByRegion
 (
     vcf => 'file.vcf'
     chrom => '1',
     start => 1000000,
     end   => 2000000,
 );

 my %search_arguments = VcfReader::getSearchArguments('file.vcf');
 my @hits = VcfReader::searchByRegion
 (
     %search_arguments,
     chrom => '1',
     start => 1000000,
     end   => 2000000,
 );

=cut
sub searchByRegion{
    #get all variants within a genomic region
    my (%args) = @_;
    croak "chrom argument is required for searchForPosition method " if not exists $args{chrom};
    croak "start argument is required for searchForPosition method " if not exists $args{start};
    croak "end argument is required for searchForPosition method " if not exists $args{end};
    if (exists $args{vcf}){
        if ($args{vcf} =~ /\.(b){0,1}gz$/){
            return searchByRegionCompressed(%args);
        }else{
            return searchByRegionUncompressed(%args);
        }
    }elsif(exists $args{tabix_iterator}){
        return searchByRegionCompressed(%args);
    }elsif(exists $args{file_handle}){
        croak "file_handle argument can only be used without vcf argument if contig_order is provided "
            if not $args{contig_order};
        return searchByRegionUncompressed(%args);
    }else{
        croak "vcf or tabix_iterator arguments are required for searchForPosition method " ;
    }
}



=item B<searchByRegionCompressed>

Searches a VCF exactly as the 'searchByRegion' method except that this is explictly for bgzip compressed VCFs. Returns an array of variants if any are found.

Arguments

=over 16

=item vcf

File name of VCF file to search. This argument or 'tabix_iterator' argument is required.

=item tabix_iterator

A tabix iterator object for a bgzip compressed VCF. Can be used instead of or with 'vcf' argument. Will be created if not provided.

=item chrom

Name of chromosome to search. Required.

=item start

Start coordinate of region to search. Required.

=item end

End coordinate of region to search. Required.

=item iter

Return a tabixIterator for the given query rather than an array of hits.

=back 


 my @hits = VcfReader::searchByRegionCompressed
 (
     vcf => 'file.vcf.gz'
     chrom => '1',
     start => 1000000,
     end   => 2000000,
 );

=cut
sub searchByRegionCompressed{
    my (%args) = @_;
    croak "chrom argument is required for searchByRegionCompressed method " if not exists $args{chrom};
    croak "start argument is required for searchByRegionCompressed method " if not exists $args{start};
    croak "end argument is required for searchByRegionCompressed method " if not exists $args{end};
    croak "vcf or tabix_iterator arguments are required for searchForPositionCompressed method " 
        if not exists $args{vcf} and not exists $args{tabix_iterator};
    eval "use Bio::DB::HTS::Tabix; 1" 
        or croak "Bio::DB::HTS::Tabix module is not installed and VCF file $args{vcf} appears to be (b)gzip compressed.  ".
        "  Please install Bio::DB::HTS::Tabix in order to search bgzip compressed VCFs.\n";
    
    my $tabixIterator; 
    if ($args{tabix_iterator}){
        $tabixIterator = $args{tabix_iterator};
    }else{
        my $index = defined $args{index} ? $args{index} : "$args{vcf}.tbi";
        if (not -e $index){
            print STDERR "Indexing $args{vcf} with tabix...";
            indexVcf($args{vcf});
            croak "Tabix indexing failed? $index does not exist " if (not -e $index);
            print STDERR " Done.\n";
        }
        $tabixIterator = Bio::DB::HTS::Tabix->new(filename =>  $args{vcf}) ;
    }
    my $iter = $tabixIterator->query_full($args{chrom}, $args{start}, $args{end});
    if ($args{iter}){
        return $iter;
    }
    my @matches = ();
    if (defined $iter){
        while (my $m =  $iter->next() ){ 
            push @matches, $m;
        } 
    } 
    return @matches if defined wantarray;
    carp "searchByRegionCompressed called in void context ";     
}

=item B<searchByRegionUncompressed>

Searches a VCF exactly as the 'searchByRegion' method except that this is explictly for uncompressed VCFs. Returns an array of variants if any are found.

Arguments

=over 16

=item vcf

File name of VCF file to search. This argument or 'tabix_iterator' argument is required.

=item file_handle

A file handle for the VCF to search. Only for uncompressed VCFs. Can be used instead of or in addition to 'vcf' argument. However, if used without 'vcf' argument the 'contig_order' argument is required in order to give index information.

=item chrom

Name of chromosome to search. Required.

=item start

Start coordinate of region to search. Required.

=item end

End coordinate of region to search. Required.

=back 


 my @hits = VcfReader::searchByRegionUncompressed
 (
     vcf => 'file.vcf'
     chrom => '1',
     start => 1000000,
     end   => 2000000,
 );


=cut
sub searchByRegionUncompressed{
    my (%args) = @_;
    croak "chrom argument is required for searchByRegionUncompressed method " if not exists $args{chrom};
    croak "start argument is required for searchByRegionUncompressed method " if not exists $args{start};
    croak "end argument is required for searchByRegionUncompressed method " if not exists $args{end};
    croak "vcf or file_handle arguments are required for searchByRegionUncompressed method " 
        if not exists $args{vcf} and not exists $args{file_handle};
    my $contig_order;
    my $blocks;
    my $FH = exists $args{file_handle} ? $args{file_handle} : _openFileHandle($args{vcf});
    my $index;
    my $contig_index;
    if ($args{vcf}){
        $index = defined  $args{index} ?  $args{index} : "$args{vcf}.vridx" ;
    }
    if (exists $args{contig_order}){
        if (ref $args{contig_order} eq 'HASH'){
            $contig_order = $args{contig_order};
        }else{
            croak "contig_order argument passed to searchByRegionUncompressed method must be a hash reference ";
        }
    }else{
        croak "contig_order argument is required to use searchByRegionUncompressed without vcf argument "
            if not exists $args{vcf};
    }
    if (not $contig_order){
        my %c  = readIndex($args{vcf});
        $contig_order = \%c;
        if (not %{$contig_order}){
            croak "Could not find any contigs in contig index $args{vcf}.vridx. Try deleting $args{vcf}.vridx and rerunning " ;
        }
    }

    my @matches = _getByRegion(
                            chrom           => $args{chrom}, 
                            end             => $args{end},
                            start           => $args{start},
                            contig_order    => $contig_order,
                            fh              => $FH,
                            );
    return @matches if defined wantarray;
    carp "searchByRegionUncompressed called in void context ";     
}

sub _getByRegion{
    my (%args) = @_;
    croak "chrom argument is required for _getByRegion method " if not exists $args{chrom};
    croak "start argument is required for _getByRegion method " if not exists $args{start};
    croak "end argument is required for _getByRegion method " if not exists $args{end};
    croak "contig_order argument is required for _getByRegion method " if not exists $args{contig_order};
    #croak "index argument is required for _getByRegion method " if not exists $args{index};
    croak "fh argument is required for _getByRegion method " if not exists $args{fh};
    #my $total_lines = exists $args{length} ? $args{length} : get_file_length_from_index($args{fh}, $args{index}); 
    if ($args{start} > $args{end}){
        my $start = $args{end};
        $args{end} = $args{start};
        $args{start} = $start;
    }
    my @searches = ();
    my @matches = ();
    my $start_to_int = int($args{start}/$REGION_SPANS);
    my $end_to_int = int($args{end}/$REGION_SPANS);
    my $start_rounddown = int($args{start}/$REGION_SPANS) * $REGION_SPANS;
    my $end_rounddown = int($args{end}/$REGION_SPANS) * $REGION_SPANS;
    for (my $i = $start_to_int; $i <= $end_to_int; $i++){
        my $span_start = $i * $REGION_SPANS;
        if (exists $args{contig_order}->{$args{chrom}}->{regions}->{$span_start}){
            push @searches, $args{contig_order}->{$args{chrom}}->{regions}->{$span_start};
        }
    }
    foreach my $s (@searches){
        foreach my $reg (@$s){
            next if $reg->{pos_start} > $args{end};
            next if $reg->{pos_end} < $args{start};
            my @lines = _readLinesByOffset($reg->{offset_start}, $reg->{offset_end}, $args{fh});
            foreach my $l (@lines){
                my @sp = split("\t", $l);
                my $l_pos =  $sp[VCF_FIELDS->{POS}]; 
                last if $l_pos > $args{end};
                if ($l_pos >= $args{start} and $l_pos <= $args{end}){
                    push @matches, $l;
                    next;
                }
                my $span = getSpan (\@sp);
                if ($l_pos <= $args{end} and $span >= $args{start}){
                    push @matches, $l;
                }
            }
        }
    }
    my %seen = ();
    @matches = grep {! $seen{$_}++} @matches;
    return @matches;
}

=item B<searchForPosition>

Searches a VCF for variants that overlap a given genomic coordinate. Runs the appropriate search method depending on file extension - that is if a file has a '.gz' extension bgzip compression is assumed, otherwise uncompressed data is expected. Returns an array of variants if any are found.

Arguments

=over 16

=item vcf

File name of VCF file to search. This argument, 'file_handle' or 'tabix_iterator' argument is required.

=item file_handle

A file handle for the VCF to search. Only for uncompressed VCFs. Can be used instead of or in addition to 'vcf' argument. However, if used without 'vcf' argument the 'contig_order' argument is required in order to give index information.

=item contig_order

Contig order index hash as obtained from the 'readIndex' function. For use with uncompressed VCFs only. If not provided the index will be read, assuming the 'vcf' argument has been used to specify the filename.

=item tabix_iterator

A tabix iterator object for a bgzip compressed VCF. Can be used instead of or with 'vcf' argument. Will be created if not provided.

=item chrom

Name of chromosome to search. Required.

=item pos

Coordinate to search. Required.


=back 


 my @hits = VcfReader::searchForPosition
 (
     vcf => 'file.vcf'
     chrom => '1',
     pos => 1000000,
 );

 my %search_arguments = VcfReader::getSearchArguments('file.vcf');
 my @hits = VcfReader::searchForPosition
 (
     %search_arguments,
     chrom => '1',
     pos => 1000000,
 );



=cut
sub searchForPosition{
#if vcf argument is provided will use Tabix.pm (searchForPositionCompressed) or internal method (searchForPositionUncompressed)
#depending on file extension
#otherwise will use Tabix.pm if tabix_iterator argument is provided
#or internal method if file_handle argument is provided
    my (%args) = @_;
    croak "chrom argument is required for searchForPosition method " if not exists $args{chrom};
    croak "pos argument is required for searchForPosition method " if not exists $args{pos};
    if (exists $args{vcf}){
        if ($args{vcf} =~ /\.(b){0,1}gz$/){
            return searchForPositionCompressed(%args);
        }else{
            return searchForPositionUncompressed(%args);
        }
    }elsif(exists $args{tabix_iterator}){
        return searchForPositionCompressed(%args);
    }elsif(exists $args{file_handle}){
        croak "file_handle argument can only be used without vcf argument if contig_order is provided "
            if not $args{contig_order};
        return searchForPositionUncompressed(%args);
    }else{
        croak "vcf or tabix_iterator arguments are required for searchForPosition method " ;
    }
}
 
=item B<searchForPositionCompressed>

Searches a VCF exactly as the 'searchForPosition' method except that this is explictly for bgzip compressed VCFs. Returns an array of variants if any are found.

Arguments

=over 16

=item vcf

File name of VCF file to search. This argument or 'tabix_iterator' argument is required.

=item tabix_iterator

A tabix iterator object for a bgzip compressed VCF. Can be used instead of or with 'vcf' argument. Will be created if not provided.

=item chrom

Name of chromosome to search. Required.

=item pos

Coordinate to search. Required.


=back 


 my @hits = VcfReader::searchForPositionCompressed
 (
     vcf => 'file.vcf.gz'
     chrom => '1',
     pos => 1000000,
 );


=cut
sub searchForPositionCompressed{
    my (%args) = @_;
    croak "chrom argument is required for searchForPositionCompressed method " if not exists $args{chrom};
    croak "pos argument is required for searchForPositionCompressed method " if not exists $args{pos};
    croak "vcf or tabix_iterator arguments are required for searchForPositionCompressed method " 
        if not exists $args{vcf} and not exists $args{tabix_iterator};
    eval "use Bio::DB::HTS::Tabix; 1" 
        or croak "Tabix module is not installed and VCF file $args{vcf} appears to be (b)gzip compressed.  ".
        "  Please install Bio::DB::HTS::Tabix in order to search bgzip compressed VCFs.\n";
    
    my $tabixIterator; 
    if ($args{tabix_iterator}){
        $tabixIterator = $args{tabix_iterator};
    }else{
        my $index = defined $args{index} ? $args{index} : "$args{vcf}.tbi";
        if (not -e $index){
            print STDERR "Indexing $args{vcf} with tabix...";
            indexVcf($args{vcf});
            croak "Tabix indexing failed? $index does not exist " if (not -e $index);
            print STDERR " Done.\n";
        }
        $tabixIterator = Bio::DB::HTS::Tabix->new(filename =>  $args{vcf}) ;
    }
    my $iter = $tabixIterator->query_full($args{chrom}, $args{pos}, $args{pos});
    my @matches = ();
    if (defined $iter){
        while (my $m =  $iter->next()){
            push @matches, $m;
        } 
    } 
    return @matches if defined wantarray;
    carp "searchForPositionCompressed called in void context ";     
}          

=item B<searchForPositionUncompressed>

Searches a VCF exactly as the 'searchByRegion' method except that this is explictly for uncompressed VCFs. Returns an array of variants if any are found.

Arguments

=over 16

=item vcf

File name of VCF file to search. This argument or 'tabix_iterator' argument is required.

=item file_handle

A file handle for the VCF to search. Only for uncompressed VCFs. Can be used instead of or in addition to 'vcf' argument. However, if used without 'vcf' argument the 'contig_order' argument is required in order to give index information.

=item chrom

Name of chromosome to search. Required.

=item pos

Coordinate to search. Required.

=back 


 my @hits = VcfReader::searchForPositionUncompressed
 (
     vcf => 'file.vcf'
     chrom => '1',
     pos => 1000000,
 );

=cut
sub searchForPositionUncompressed{
    my (%args) = @_;
    croak "chrom argument is required for searchForPositionUncompressed method " if not exists $args{chrom};
    croak "pos argument is required for searchForPositionUncompressed method " if not exists $args{pos};
    croak "vcf or file_handle arguments are required for searchForPositionUncompressed method " 
        if not exists $args{vcf} and not exists $args{file_handle};
    my $contig_order;
    my $blocks;
    my $FH = exists $args{file_handle} ? $args{file_handle} : _openFileHandle($args{vcf});
    my $index;
    my $contig_index;
    if ($args{vcf}){
        $index = defined  $args{index} ?  $args{index} : "$args{vcf}.vridx" ;
    }
    if (exists $args{contig_order}){
        if (ref $args{contig_order} eq 'HASH'){
            $contig_order = $args{contig_order};
        }else{
            croak "contig_order argument passed to searchForPositionUncompressed method must be a hash reference ";
        }
    }else{
        croak "contig_order argument is required to use searchForPositionUncompressed without vcf argument "
            if not exists $args{vcf};
    }
    if (not $contig_order){
        my %c  = readIndex($args{vcf});
        $contig_order = \%c;
        if (not %{$contig_order}){
            croak "Could not find any contigs in contig index $args{vcf}.vridx. Try deleting $args{vcf}.vridx and rerunning " ;
        }
    }

    my @matches = _searchVcf(
                            chrom           => $args{chrom}, 
                            pos             => $args{pos},
                            contig_order    => $contig_order,
                            fh              => $FH,
                            );
    return @matches if defined wantarray;
    carp "searchForPositionUncompressed called in void context ";     
}

sub _searchVcf{
    my (%args) = @_;
    croak "chrom argument is required for _searchVcf method " if not exists $args{chrom};
    croak "pos argument is required for _searchVcf method " if not exists $args{pos};
    croak "contig_order argument is required for _searchVcf method " if not exists $args{contig_order};
    #croak "index argument is required for _searchVcf method " if not exists $args{index};
    croak "fh argument is required for _searchVcf method " if not exists $args{fh};
    #my $total_lines = exists $args{length} ? $args{length} : get_file_length_from_index($args{fh}, $args{index}); 
    my @matches = ();
    my $pos_rounddown = int($args{pos}/$REGION_SPANS) * $REGION_SPANS;
    return if not (exists $args{contig_order}->{$args{chrom}}->{regions}->{$pos_rounddown});
    foreach my $reg (@{$args{contig_order}->{$args{chrom}}->{regions}->{$pos_rounddown}}){
        next if $reg->{pos_start} > $args{pos};
        next if $reg->{pos_end} < $args{pos};
        my @lines = _readLinesByOffset($reg->{offset_start}, $reg->{offset_end}, $args{fh});
        foreach my $l (@lines){
            my @sp = split("\t", $l);
            my $l_pos =  $sp[VCF_FIELDS->{POS}]; 
            last if $l_pos > $args{pos};
            if ($l_pos == $args{pos}){
                push @matches, $l;
                next;
            }
            my $span = getSpan(\@sp);
            if ($l_pos <= $args{pos} and $span >= $args{pos}){
                push @matches, $l;
            }
        }
    }
    return @matches;
}

sub _readLinesByOffset{
    my ($start, $end, $fh) = @_;
    my $data = '';
    sysseek ($fh, $start, SEEK_SET);
    sysread($fh, $data, $end - $start, 0);
    return split("\n", $data);
}

=back


=head2 VEP Utilities

=item B<readVepHeader>

Reads the header of a VCF and returns a hash of VEP consequence fields to their index in output.

Arguments

=over 16

=item vcf

File name of VCF file to search. This argument or 'header' argument is required.

=item header

Header string or an array of header lines in the same order they appear in a file. Ignored if using 'vcf' argument.

=back 


 my %vep_header = VcfReader::readVepHeader(vcf => 'file.vcf');
 
 my %vep_header = VcfReader::readVepHeader(header => \@header);

=cut

sub readVepHeader{
    my (%args) = @_;
    croak "Invalid header " if not checkHeader(%args);
    my %vep_fields = ();
    my @header = ();
    if ($args{vcf}){
        @header = getHeader($args{vcf});
    }elsif($args{header}){
        if (ref $args{header} eq 'ARRAY'){
            @header = @{$args{header}};
        }else{
            @header = split("\n", $args{header});
        }
    }
    my @info = grep{/^##INFO=<ID=CSQ/} @header;
    if (not @info){
        croak "Method 'readVepHeader' requires CSQ INFO field in meta header (e.g. '##INFO=<ID=CSQ,Number...') but no matching lines found ";
    }
    carp "Warning - multiple CSQ fields found, ignoring all but the most recent field " if @info > 1;
   my $csq_line = $info[-1] ;#assume last applied VEP consequences are what we are looking for 
   my @csq_fields = ();    
   if ($csq_line =~ /Format:\s(\S+\|\S+)">/){
       @csq_fields = split(/\|/, $1);
   }else{
       croak "Method 'readVepHeader' couldn't properly read the CSQ format from the corresponding INFO line: $csq_line ";
   }
   if (not @csq_fields){
       croak "Method 'readVepHeader' didn't find any VEP fields from the corresponding CSQ INFO line: $csq_line ";
   }
   for (my $i = 0; $i < @csq_fields; $i++){
       $vep_fields{lc($csq_fields[$i])} = $i;
   }
    return %vep_fields;
}

=item B<getVepFields>

Reads a VEP annotated VCF record and returns the annotations corresponding to either a single or multiple fields as an array or array of hashes respectively. 

Arguments

=over 16

=item line

Array reference to a split line to be passed as the first argument. Required.

=item vep_header

Reference to a hash of CSQ fields to their index in the output as retrieved using the 'readVepHeader' method. Required.

=item field

Name of a CSQ field to retrieve or an array reference to the names of several CSQ fields to retrieve. Can also use 'all' to retrieve all CSQ fields. Required.


=back 


 my %vep_header = VcfReader::readVepHeader(header => \@header);
 my @all_genes  = VcfReader::getVepFields
 (
    line       => \@split_line,
    vep_header => \%vep_header,
    field      => 'gene',
 );
    
 my @gene_cons_pph  = VcfReader::getVepFields
 (
    line       => \@split_line,
    vep_header => \%vep_header,
    field      => [gene, consequence, polyphen],
 );

 my @all_vep = VcfReader::getVepFields
 (
    line       => \@split_line,
    vep_header => \%vep_header,
    field      => 'all',
 );

=cut

sub getVepFields{
    my (%args) = @_;
    foreach my $ar (qw / line vep_header field / ){
        croak "Argument $ar is required for getVepFields method.\n" if not exists $args{$ar};
    }
    croak "line argument must be an array reference " if ref $args{line} ne 'ARRAY';
    croak "vep_header argument must be a hash reference " if ref $args{vep_header} ne 'HASH';
    my @return;
    my @fields = ();
    my $inf_csq = getVariantInfoField($args{line}, 'CSQ');
    croak "No CSQ field found in INFO field for line " . join("\t", @{$args{line}}) . "\n" if not $inf_csq;
    my @csqs = split(",", $inf_csq);
    foreach my $c (@csqs){#foreach feature (e.g. transcript) 
        my %t_csq = ();
        my @v = split(/[\|]/, $c);
        if (ref $args{field} eq 'ARRAY'){
            @fields =  @{$args{field}};
        }elsif (lc($args{field}) eq 'all'){
            @fields = keys %{$args{vep_header}};
        }else{#if a single field we return an array of values, not hash refs
            if (not exists $args{vep_header} -> {lc($args{field})}){
                carp "$args{field} feature does not exist in CSQ field ";
            }else{
                 push @return, $v[ $args{vep_header} -> {lc($args{field})} ];
                 next;
            }
        }
        foreach my $f (@fields){#for multiple fields we return an array of hash refs
            if (not exists $args{vep_header} -> {lc($f)}){
                carp "$f feature does not exist in CSQ field ";
                next;
            }
            $t_csq{lc$f} = defined $v[ $args{vep_header} -> {lc($f)} ] ? 
                                   $v[ $args{vep_header} -> {lc($f)} ] : 
                                   '';
            
        }
        push @return, \%t_csq;
    }
    return @return;
}
 
=item B<altsToVepAllele>

Returns a list of VEP style alleles in the same order as alt alleles passed to it. Pass either a VCF record in the form of a split line or all ALTs and the REF allele for a given record in order to convert the alleles appropriately for a VCF line.

Arguments

=over 16

=item line

Array reference to a split line to be passed as the first argument. Required unless using 'ref' and 'alt' arguments.

=item ref

String representing the REF allele for all ALT alleles specified by 'alts' argument. Required unless using 'line' argument. 

=item alts

Referemce to an array of ALT alleles to convert. Required unless using 'line' argument.

=back 


 my @vep_alts = VcfReader::altsToVepAllele
 (
    line => \@split_line,
 );

 my @vep_alts = VcfReader::altsToVepAllele
 (
    ref  => 'A',
    alts => ['AA', 'C', 'T'],
 );
    
=cut

sub altsToVepAllele{
    my (%args) = @_;
    my $ref;
    my @alts = ();
    if (exists $args{line}){
        croak "line argument must be an array reference " if ref $args{line} ne 'ARRAY';
        $ref  = getVariantField($args{line}, 'REF');
        @alts = getVariantField($args{line}, 'ALT');
    }else{
        croak "'ref' or 'line' argument is required for altsToVepAllele " 
            if not exists $args{ref};
        croak "'alts' or 'line' argument is required for altsToVepAllele " 
            if not exists $args{alts};
        croak "alts argument must be an array reference " if ref $args{alts} ne 'ARRAY';
        $ref = $args{ref};
        @alts = @{$args{alts}};
    }
    return _altToVep(\@alts, $ref);
}


#convert alts to VEP style alleles   
sub _altToVep{
    my ($alt_array, $ref) = @_;
    my @vep_alleles = ();
    my $start_differs = 0;
    my $is_indel = 0; 
    my $is_snv = 0;
    my $is_mnv = 0;
    foreach my $alt (@$alt_array){
        next if $alt eq '*';
        if (length($alt) == 1 and length($ref) == 1){
            $is_snv = 1;
        }elsif (length($alt) == length($ref) ){
            $is_mnv++;
        }else{
            $is_indel++;
        }
    }
    if ($is_snv or ($is_mnv and not $is_indel) ){
        #in this situation VEP does not trim any variant alleles
        foreach my $alt (@$alt_array){
            push @vep_alleles, $alt;
        }
    }else{
        my $refstart = substr($ref, 0, 1); 
        foreach my $alt (@$alt_array){
            next if $alt eq '*';
            my $altstart = substr($alt, 0, 1); 
            if ($altstart ne $refstart){
                $start_differs++; 
                last;
            }
        }
        foreach my $alt (@$alt_array){
            if ($alt eq '*'){
                push @vep_alleles, $alt;
            }elsif ($start_differs){#no trimming if the first base differs for any ALT
                push @vep_alleles, $alt;
            }else{#VEP trims first base or gives '-' if ALT is only 1 nt long
                if (length($alt) > 1){
                    push @vep_alleles,  substr($alt, 1);
                }else{
                    push @vep_alleles,  '-';
                }
            }
        }
    }
    return @vep_alleles;
}

=head2 SnpEff Utilities

=item B<readSnpEffHeader>

Reads the header of a VCF and returns a hash of SnpEff consequence fields to their index in output. Only 'ANN' annotations are supported, not old style 'EFF' annotations.

Arguments

=over 16

=item vcf

File name of VCF file to search. This argument or 'header' argument is required.

=item header

Header string or an array of header lines in the same order they appear in a file. Ignored if using 'vcf' argument.

=back 


 my %snpeff_header = VcfReader::readSnpEffHeader(vcf => 'file.vcf');
 
 my %snpeff_header = VcfReader::readSnpEffHeader(header => \@header);

=cut

sub readSnpEffHeader{
    my (%args) = @_;
    croak "Invalid header " if not checkHeader(%args);
    my %snpeff_fields = ();
    my @header = ();
    if ($args{vcf}){
        @header = getHeader($args{vcf});
    }elsif($args{header}){
        if (ref $args{header} eq 'ARRAY'){
            @header = @{$args{header}};
        }else{
            @header = split("\n", $args{header});
        }
    }

    my @info = grep{/^##INFO=<ID=ANN/} @header;
    if (not @info){
        croak "Method 'readSnpEffHeader' requires ANN INFO field in meta header (e.g. '##INFO=<ID=ANN,Number...') but no matching lines found ";
    }
    carp "Warning - multiple ANN fields found, ignoring all but the most recent field " if @info > 1;
   my $csq_line = $info[-1] ;#assume last applied SnpEff consequences are what we are looking for 
   my @csq_fields = ();    
   if ($csq_line =~ /Description="Functional annotations: '(.+)'\s*">/){
       @csq_fields = split(/\s+\|\s+/, $1);
   }else{
       croak "Method 'readSnpEffHeader' couldn't properly read the ANN format from the corresponding INFO line: $csq_line ";
   }
   if (not @csq_fields){
       croak "Method 'readSnpEffHeader' didn't find any SnpEff fields from the corresponding ANN INFO line: $csq_line ";
   }
   for (my $i = 0; $i < @csq_fields; $i++){
       $snpeff_fields{lc($csq_fields[$i])} = $i;
   }
    return %snpeff_fields;
}

=item B<getSnpEffFields>

Reads a VEP annotated VCF record and returns the annotations corresponding to either a single or multiple fields as an array or array of hashes respectively. 

Arguments

=over 16

=item line

Array reference to a split line to be passed as the first argument. Required.

=item snpeff_header

Reference to a hash of ANN fields to their index in the output as retrieved using the 'readSnpEffHeader' method. Required.

=item field

Name of an ANN field to retrieve or an array reference to the names of several ANN fields to retrieve. Can also use 'all' to retrieve all ANN fields. Required.


=back 


 my %snpeff_header = VcfReader::readSnpEffHeader(header => \@header);
 my @all_genes  = VcfReader::getSnpEffFields
 (
    line          => \@split_line,
    snpeff_header => \%snpeff_header,
    field         => 'gene',
 );
    

 my @all_snpeff = VcfReader::getSnpEffFields
 (
    line          => \@split_line,
    snpeff_header => \%snpeff_header,
    field         => 'all',
 );

=cut

sub getSnpEffFields{
    my (%args) = @_;
    foreach my $ar (qw / line snpeff_header field / ){
        croak "Argument $ar is required for getSnpEffFields method.\n" if not exists $args{$ar};
    }
    croak "line argument must be an array reference " if ref $args{line} ne 'ARRAY';
    croak "snpeff_header argument must be a hash reference " if ref $args{snpeff_header} ne 'HASH';
    my @return;
    my @fields = ();
    my $inf_csq = getVariantInfoField($args{line}, 'ANN');
    croak "No ANN field found in INFO field for line " . join("\t", @{$args{line}}) . "\n" if not $inf_csq;
    my @csqs = split(",", $inf_csq);
    foreach my $c (@csqs){#foreach feature (e.g. transcript) 
        my %t_csq = ();
        my @v = split(/[\|]/, $c);
        if (ref $args{field} eq 'ARRAY'){
            @fields =  @{$args{field}};
        }elsif (lc($args{field}) eq 'all'){
            @fields = keys %{$args{snpeff_header}};
        }else{#if a single field we return an array of values, not hash refs
            if (not exists $args{snpeff_header} -> {lc($args{field})}){
                carp "$args{field} feature does not exist in ANN field ";
            }else{
                 push @return, $v[ $args{snpeff_header} -> {lc($args{field})} ];
                 next;
            }
        }
        foreach my $f (@fields){#for multiple fields we return an array of hash refs
            if (not exists $args{snpeff_header} -> {lc($f)}){
                carp "$f feature does not exist in ANN field ";
                next;
            }
            $t_csq{lc$f} = $v[ $args{snpeff_header} -> {lc($f)} ];
        }
        push @return, \%t_csq;
    }
    return @return;
}
 
=cut


=head1 AUTHOR

David A. Parry

=head1 COPYRIGHT AND LICENSE

Copyright 2014, 2015  David A. Parry

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with this program. If not, see <http://www.gnu.org/licenses/>.

=cut
1;
