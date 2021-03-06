package EnsemblRestQuery;

use strict;
use warnings;
use Carp;
use HTTP::Tiny;
use JSON;
use Time::HiRes;
use FindBin qw($RealBin);
use lib "$RealBin";
use IdParser;

our $VERSION = 0.1;
our $AUTOLOAD;

##################################################

{
        my $_count = 0;
        my %_attrs = (
        _server         => ["http://rest.ensembl.org", "read/write"],
        _default_server => ["http://rest.ensembl.org", "read"],
        _grch37_server  => ["http://grch37.rest.ensembl.org", "read"],
        );
        sub _all_attrs{
                keys %_attrs;
        }
        sub _accessible{
                my ($self, $attr, $mode) = @_;
                $_attrs{$attr}[1] =~ /$mode/
        }
        sub _attr_default{
                my ($self, $attr) = @_;
                $_attrs{$attr}[0];
        }
        sub get_count{
                $_count;
        }
        sub _incr_count{
                $_count++;
        }
        sub _decr_count{
                $_count--;
        }

}

##################################################

sub DESTROY{
    my ($self) = @_;
    $self -> _decr_count( );
}

##################################################

sub new {
    my ($class, %args) = @_;
    my $self = bless { }, $class;
    foreach my $attr ($self -> _all_attrs( ) ){
        my ($arg) = ($attr =~ /^_(.*)/);
        if (exists $args{$arg}){
            $self->{$attr} = $args{$arg};
        }elsif($self->_accessible($attr, "required")){
            croak "$attr argument required";
        }else{
            $self->{$attr} = $self->_attr_default($attr);
        }
    }
    $self->{_http} = HTTP::Tiny->new();
    $class -> _incr_count();
    return $self;
}

##################################################

sub AUTOLOAD{
    my ($self, $val) = @_;
    no strict 'refs';
    if ($AUTOLOAD =~ /.*::get(_\w+)/ and $self -> _accessible($1, "read")){
        my $attr = $1;
        croak "No such attribute \"$attr\"" unless exists $self->{$attr};
        *{$AUTOLOAD} = sub { return $_[0] -> {$attr} };
        return $self->{$attr};
    }elsif ($AUTOLOAD =~ /.*::set(_\w+)/ and $self -> _accessible($1, "write")){
        my $attr = $1;
        croak "No such attribute \"$attr\"" unless exists $self->{$attr};
        *{$AUTOLOAD} = sub { $_[0] -> {$attr} = $_[1]; return ; };
        $self -> {$attr} = $val;
        return
    }else{
        croak "Method name \"$AUTOLOAD\" not available";
    }
}



##################################################

sub ensRestQuery{
    my $self = shift;
    my $url = shift;
    $self->{_requestCount}++;    
    if ($self->{_requestCount} == 15) { # check every 15
        my $current_time = Time::HiRes::time();
        my $diff = $current_time - $self->{_lastRequestTime};
        # if less than a second then sleep for the remainder of the second
        if($diff < 1) {
            Time::HiRes::sleep(1-$diff);
        }
        # reset
        $self->{_requestCount} = 0;
    }
    $self->{_lastRequestTime} = Time::HiRes::time();
    my $response = $self->{_http}->get($url, {
          headers => { 'Content-type' => 'application/json' }
    });
    my $status = $response->{status};
    if (not $response->{success}){
        if($status == 429 && exists $response->{headers}->{'retry-after'}) {
            my $retry = $response->{headers}->{'retry-after'};
            Time::HiRes::sleep($retry);
            return $self->ensRestQuery($url); 
        }
        my $reason = $response->{reason};
        carp "Ensembl REST query ('$url') failed: Status code: ${status}. Reason: ${reason}\n" ;
        return;
    }

    if(length $response->{content}) {
        return decode_json($response->{content});
    }
    carp "No content for Ensembl REST query ('$url')!\n";
    return;
}

##################################################
sub queryEndpoint{
    my $self = shift;
    my $endpoint = shift;
    $endpoint = "/$endpoint" if $endpoint !~ /^\//;
    my $url = $self->{_server} . $endpoint;
    return $self->ensRestQuery($url); 
}
 
##################################################

sub getViaXreg{
    my ($self, $id, $species, $object_type) = @_;
    my $endpoint = "/xrefs/symbol/$species/$id?object_type=$object_type";
    my $url = $self->{_server} . $endpoint;
    return $self->ensRestQuery($url); 
}

##################################################

sub getTranscriptViaXreg{
    my ($self, $id, $species) = @_;
    return $self->getViaXreg($id, $species, 'transcript');
}
 
##################################################

sub getGeneViaXreg{
    my ($self, $id, $species) = @_;
    return $self->getViaXreg($id, $species, 'gene');
}
    

##################################################

sub lookUpEnsId{
    my ($self, $id, $expand) = @_;
    my $endpoint = "/lookup/id/$id";
    if ($expand){
        $endpoint .= "?expand=1";
    }
    my $url = $self->{_server} . $endpoint;
    return $self->ensRestQuery($url); 
} 

##################################################

sub getParent{
    my ($self, $id, $expand) = @_;
    my $endpoint = "/lookup/id/$id";
    my $url = $self->{_server} . $endpoint;
    my $hash = $self->ensRestQuery($url);
    return if not $hash;
    if ($hash->{Parent}){
        return $self->lookUpEnsId($hash->{Parent}, $expand);
    }else{
        return;
    }
}

##################################################

sub transcriptFromEnsp{
    my ($self, $id, $expand) = @_;
    $self->getParent($id, $expand);
}

##################################################

sub geneFromTranscript{
    my ($self, $id, $expand) = @_;
    $self->getParent($id, $expand);
}

##################################################
sub geneFromEnsp{
    my ($self, $id, $expand) = @_;
    my $par = $self->getParent($id);
    if ($par){
        if (exists $par->{id}){
            return $self->geneFromTranscript($par->{id}, $expand);
        }
    }
}
##################################################

sub getXrefs{
    my ($self, %args) = @_;
    if (not $args{id}){
        carp "'id' argument is required for getXrefs method\n";
        return;
    }
    my $endpoint = "/xrefs/id/$args{id}";
    my @extra_args = ();
    if ($args{all_levels}){
        push @extra_args, "all_levels=$args{all_levels}";
    }
    if ($args{db}){
        push @extra_args, "external_db=$args{db}";
    }
    $endpoint .= "?" . join(";", @extra_args); 
    my $url = $self->{_server} . $endpoint;
    return $self->ensRestQuery($url); 
}

##################################################
sub proteinPosToGenomicPos{
    my ($self, %args) = @_;
    if (not $args{id}){
        carp "'id' argument is required for method\n";
        return;
    }
    if (not $args{start}){
        carp "'start' argument is required for method\n";
        return;
    }
    $args{end} ||= $args{start}; 
    my $endpoint = "/map/translation/$args{id}/$args{start}..$args{end}";
    my $url = $self->{_server} . $endpoint;
    return $self->ensRestQuery($url); 
}

##################################################
sub useGRCh37Server{
    my $self = shift;
    $self->{_server} = $self->{_grch37_server};
}

##################################################
sub useDefaultServer{
    my $self = shift;
    $self->{_server} = $self->{_default_server};
}

##################################################
sub getGeneDetails{
    my ($self, $id, $species) = @_;
    my $gene_hash; 
    my $id_parser = new IdParser();
    $id_parser->parseId($id);
    my @lookups = ();
    if ($id_parser->get_isEnsemblId()){
        if ( $id_parser->get_isTranscript() ){
            $gene_hash = $self->geneFromTranscript($id, 1);
        }elsif( $id_parser->get_isProtein() ) {
            $gene_hash = $self->geneFromEnsp($id, 1);
        }else{
            $gene_hash = $self->lookUpEnsId($id, 1);
        }
    }elsif($id_parser->get_isTranscript()  or $id_parser->get_isProtein() ) {
        my $transcript = $self->getTranscriptViaXreg($id, $species);
        if ($transcript and ref $transcript eq 'ARRAY'){
            if (@$transcript > 1){
                carp "WARNING: Multiple transcripts identified by ".
                  "cross-reference search for $id - picking the first.\n";
            }
            my $tr = $transcript->[0];
            if (exists $tr->{id}){
                $gene_hash = $self->geneFromTranscript($tr->{id});
            }
        }else{
            carp "WARNING: No transcript identified for ID \"$id\"\n";
        }
    }else{
        my $gene = $self->getGeneViaXreg($id, $species);
        if (ref $gene eq 'ARRAY'){
            foreach my $ge (@$gene){
                if ($ge->{id}){
                    my $ge_hash = $self->lookUpEnsId($ge->{id}, 1);
                    if (uc($ge_hash->{display_name}) eq uc($id)){
                    #if gene symbol matches then we use this entry
                        $gene_hash = $ge_hash;
                        last;
                    }else{
                        push @lookups, $ge_hash;
                    }
                }
            }
            if (not $gene_hash){
                if (@lookups == 1){
                    $gene_hash = $lookups[0];
                }
            }
        }
    }
    if (not $gene_hash){
        my $msg = "WARNING: Could not identify gene for ID \"$id\"\n";
        if (@lookups){
            my $idstring = join("\n", map { $_->{display_name} } @lookups );
            $msg .= "Identified the following non-matching display names:\n".
                         "$idstring\n";
        }
        carp $msg;
    }
    return $gene_hash;
}

##################################################
sub getTranscriptDetails{
    my ($self, $id, $species) = @_;
    my @trans_hash = ();
    my @lookups = ();
    my $id_parser = new IdParser();
    $id_parser->parseId($id);
    if ($id_parser->get_isEnsemblId()){
        if ( $id_parser->get_isTranscript() ){
            push @trans_hash, $self->lookUpEnsId($id, 1);
        }elsif( $id_parser->get_isProtein() ) {
            push @trans_hash, $self->transcriptFromEnsp($id, 1);
        }else{
            my $ge_hash = $self->lookUpEnsId($id, 1);
            @trans_hash = _transcriptsFromGeneHash($ge_hash);
        }
    }elsif($id_parser->get_isTranscript()  or $id_parser->get_isProtein() ) {
        my $transcript = $self->getTranscriptViaXreg($id, $species);
        if ($transcript and ref $transcript eq 'ARRAY'){
            if (@$transcript > 1){
                carp "WARNING: Multiple transcripts identified by ".
                  "cross-reference search for $id.\n";
            }
            @trans_hash = @$transcript;
        }else{
            carp "WARNING: No transcript identified for ID \"$id\"\n";
        }
    }else{
        my $gene = $self->getGeneViaXreg($id, $species);
        if (ref $gene eq 'ARRAY'){
            foreach my $ge (@$gene){
                if ($ge->{id}){
                    my $ge_hash = $self->lookUpEnsId($ge->{id}, 1);
                    if (uc($ge_hash->{display_name}) eq uc($id)){
                    #if gene symbol matches then we use this entry
                        @trans_hash = _transcriptsFromGeneHash($ge_hash);
                        last;
                    }else{
                        push @lookups, $ge_hash;
                    }
                }
            }
            if (not @trans_hash){
                if (@lookups == 1){
                    @trans_hash = _transcriptsFromGeneHash($lookups[0]);
                }
            }
        }
    }
    if (not @trans_hash){
        my $msg = "WARNING: Could not identify any transcripts for ID \"$id\"\n";
        if (@lookups){
            my $idstring = join("\n", map { $_->{display_name} } @lookups );
            $msg .=  "Identified the following non-matching display names:\n".
                         "$idstring\n";
        }
        carp $msg;
    }
    return @trans_hash;
}

##################################################
sub _transcriptsFromGeneHash{
    my $h = shift;
    if ($h->{Transcript}){
        return @{$h->{Transcript}};
    }
}
