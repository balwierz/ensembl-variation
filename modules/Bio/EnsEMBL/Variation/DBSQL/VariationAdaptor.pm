#
# Ensembl module for Bio::EnsEMBL::Variation::DBSQL::VariationAdaptor
#
# Copyright (c) 2004 Ensembl
#
# You may distribute this module under the same terms as perl itself
#
#

=head1 NAME

Bio::EnsEMBL::Variation::DBSQL::VariationAdaptor

=head1 SYNOPSIS

  $db = Bio::EnsEMBL::Variation::DBSQL::DBAdaptor->new(...);

  $va = $db->get_VariationAdaptor();
  $vga = $db->get_VariationGroupAdaptor();
  $pa = $db->get_PopulationAdaptor();

  # Get a Variation by its internal identifier
  $var = $va->fetch_by_dbID(145);

  # fetch a variation by its name
  $var = $va->fetch_by_name('rs100');


  # fetch all variations from a population
  $pop = $pa->fetch_by_name('PACIFIC');
  @vars = {$va->fetch_all_by_Population($pop)};

  # fetch all variations belonging to a variation group (haplotype set)
  $vg = $vga->fetch_by_name('PERLEGEN:B000009');
  @vars = @{$va->fetch_all_by_VariationGroup($vg)};


=head1 DESCRIPTION

This adaptor provides database connectivity for Variation objects.
Variations (SNPs, etc.) may be retrieved from the Ensembl variation database by
several means using this module.

=head1 AUTHOR - Graham McVicker

=head1 CONTACT

Post questions to the Ensembl development list ensembl-dev@ebi.ac.uk

=head1 METHODS

=cut

use strict;
use warnings;

package Bio::EnsEMBL::Variation::DBSQL::VariationAdaptor;

use Bio::EnsEMBL::DBSQL::BaseAdaptor;
use Bio::EnsEMBL::Utils::Exception qw(throw warning);

use Bio::EnsEMBL::Variation::Variation;
use Bio::EnsEMBL::Variation::Allele;

our @ISA = ('Bio::EnsEMBL::DBSQL::BaseAdaptor');


=head2 fetch_by_dbID

  Arg [1]    : int $dbID
  Example    : $var = $var_adaptor->fetch_by_dbID(5526);
  Description: Retrieves a Variation object via its internal identifier.
               If no such variation exists undef is returned.
  Returntype : Bio::EnsEMBL::Variation::Variation
  Exceptions : throw if dbID arg is not defined
  Caller     : general, IndividualAdaptor

=cut

sub fetch_by_dbID {
  my $self = shift;
  my $dbID = shift;

  throw('dbID argument expected') if(!defined($dbID));

  my $sth = $self->prepare
    (q{SELECT v.variation_id, v.name, v.validation_status, s1.name,
              a.allele_id, a.allele, a.frequency, a.population_id,
              vs.name, s2.name
       FROM   variation v, source s1, source s2, allele a, variation_synonym vs
       WHERE  v.variation_id = a.variation_id
       AND    v.variation_id = vs.variation_id
       AND    v.source_id = s1.source_id
       AND    vs.source_id = s2.source_id
       AND    v.variation_id = ?});
  $sth->execute($dbID);

  my $result = $self->_objs_from_sth($sth);
  $sth->finish();

  return undef if(!@$result);

  return $result->[0];
}



=head2 fetch_by_name

  Arg [1]    : string $name
  Example    : $pop = $pop_adaptor->fetch_by_name('NUSPAE:Singapore_HDL');
  Description: Retrieves a population object via its name
  Returntype : Bio::EnsEMBL::Variation::Population
  Exceptions : throw if name argument is not defined
  Caller     : general

=cut

sub fetch_by_name {
  my $self = shift;
  my $name = shift;

  throw('name argument expected') if(!defined($name));

  my $sth = $self->prepare
    (q{SELECT v.variation_id, v.name, v.validation_status, s1.name,
              a.allele_id, a.allele, a.frequency, a.population_id,
              vs.name, s2.name
       FROM   variation v, source s1, source s2, allele a, variation_synonym vs
       WHERE  v.variation_id = a.variation_id
       AND    v.variation_id = vs.variation_id
       AND    v.source_id = s1.source_id
       AND    vs.source_id = s2.source_id
       AND    v.name = ?
       ORDER BY a.allele_id});
  $sth->execute($name);

  my $result = $self->_objs_from_sth($sth);
  $sth->finish();

  if(!@$result) {
    # try again if nothing found, but check synonym table instead
    $sth = $self->prepare
      (q{SELECT v.variation_id, v.name, v.validation_status, s1.name,
                a.allele_id, a.allele, a.frequency, a.population_id,
                vs2.name, s2.name
         FROM   variation v, source s1, source s2, allele a,
                variation_synonym vs1, variation_synonym vs2
         WHERE  v.variation_id = a.variation_id
         AND    v.variation_id = vs1.variation_id
         AND    v.variation_id = vs2.variation_id
         AND    v.source_id = s1.source_id
         AND    vs2.source_id = s2.source_id
         AND    vs1.name = ?
         ORDER BY a.allele_id});
    $sth->execute($name);
    $result = $self->_objs_from_sth($sth);

    return undef if(!@$result);

    $sth->finish();
  }

  return $result->[0];
}



=head2 fetch_all_by_dbID_list

  Arg [1]    : reference to list of ints $list
  Example    : @vars = @{$va->fetch_all_by_dbID_list([124, 56, 90])};
  Description: Retrieves a set of variations via their internal identifiers.
               This is faster than repeatedly calling fetch_by_dbID if there
               are a large number of variations to retrieve
  Returntype : reference to list of Bio::EnsEMBL::Variation::Variation objects
  Exceptions : throw on bad argument
  Caller     : general, IndividualGenotypeAdaptor, PopulationGenotypeAdaptor

=cut


sub fetch_all_by_dbID_list {
  my $self = shift;
  my $list = shift;

  if(!defined($list) || ref($list) ne 'ARRAY') {
    throw("list reference argument is required");
  }

  return [] if(!@$list);

  my @out;

  # mysql is faster and we ensure that we do not exceed the max query size by
  # splitting large queries into smaller queries of 200 ids
  my $max = 200;

  while(@$list) {
    my @ids = (@$list > $max) ? splice(@$list, 0, $max) : splice(@$list, 0);

    my $id_str = (@ids > 1)  ? " IN (".join(',',@ids).")"   :   ' = '.$ids[0];

    my $sth = $self->prepare
      (qq{SELECT v.variation_id, v.name, v.validation_status, s1.name,
                 a.allele_id, a.allele, a.frequency, a.population_id,
                 vs.name, s2.name
          FROM   variation v, source s1, source s2, allele a,
                 variation_synonym vs
          WHERE  v.variation_id = a.variation_id
          AND    v.variation_id = vs.variation_id
          AND    v.source_id = s1.source_id
          AND    vs.source_id = s2.source_id
          AND    v.variation_id $id_str});
    $sth->execute();

    my $result = $self->_objs_from_sth($sth);

    $sth->finish();

    push @out, @$result if(@$result);
  }

  return \@out;
}



sub _objs_from_sth {
  my $self = shift;
  my $sth = shift;

  my ($var_id, $name, $vstatus, $source, $allele_id, $allele, $allele_freq,
      $allele_pop_id, $syn_name, $syn_source,
      $cur_allele_id, $cur_var, $cur_var_id);

  $sth->bind_columns(\$var_id, \$name, \$vstatus, \$source, \$allele_id,
                     \$allele, \$allele_freq, \$allele_pop_id, \$syn_name,
                     \$syn_source);

  my @vars;

  my %seen_syns;
  my %seen_pops;

  my $pa = $self->db()->get_PopulationAdaptor();

  while($sth->fetch()) {
    if(!defined($cur_var) || $cur_var_id != $var_id) {
      my @states = split(',',$vstatus);
      $cur_var = Bio::EnsEMBL::Variation::Variation->new
        (-dbID   => $var_id,
         -ADAPTOR => $self,
         -NAME   => $name,
         -SOURCE => $source,
         -VALIDATION_STATES => \@states);
      push @vars, $cur_var;
      $cur_var_id = $var_id;
    }

    if(!defined($cur_allele_id) || $cur_allele_id != $allele_id) {
      my $pop;
      if($allele_pop_id) {
        $pop = $seen_pops{$allele_pop_id} ||=
          $pa->fetch_by_dbID($allele_pop_id);
      }
      my $allele = Bio::EnsEMBL::Variation::Allele->new
        (-dbID      => $allele_id,
         -ALLELE    => $allele,
         -FREQUENCY => $allele_freq,
         -POPULATION => $pop);

      $cur_var->add_Allele($allele);

      $cur_allele_id = $allele_id;
    }

    if(!$seen_syns{"$syn_source:$syn_name"}) {
      $seen_syns{"$syn_source:$syn_name"} = 1;
      $cur_var->add_synonym($syn_source, $syn_name);
    }
  }

  return \@vars;
}




1;
