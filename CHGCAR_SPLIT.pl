#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin";
use Scalar::Util qw(looks_like_number);
use Storable qw(dclone);
use AtomisticFileConversion::Data2VASP qw(CHG2data Data2CHGCAR);
use AtomisticFileConversion::Data2Field qw(Data2Grd);
use AtomisticFileConversion::Util_Field qw(fields2vectField fieldGrad fieldGrad fieldVectorUnit fieldVectorDot fieldSum fieldVectorRotateSAXIS fieldZero vectField2fields fieldVoxels);
use AtomisticFileConversion::Util_System qw(fileFinder);
#use Data::Dumper;

my $saxis = [];
$$saxis[0] = shift @ARGV;
$$saxis[1] = shift @ARGV;
$$saxis[2] = shift @ARGV;

unless (
	defined($$saxis[0]) && looks_like_number($$saxis[0]) &&
	defined($$saxis[1]) && looks_like_number($$saxis[1]) &&
	defined($$saxis[2]) && looks_like_number($$saxis[2])
){
	warn ("Usage: CHGCARNCL2GRDCOLOUR.pl SAXIS-X SAXIS-Y SAXIS-Z CHGCAR-file\n");
	warn ("SAXIS-X SAXIS-Y SAXIS-Z required, must be numerical\n");
	warn ("Provided values for SAXIS: $$saxis[0] $$saxis[1] $$saxis[2]\n");
	warn ("SAXIS not numerical\n");
	warn ("CHGCAR-file optional, default is ./CHGCAR\n");
	die;
}	

my $saxis_text = "SAXIS=$$saxis[0] $$saxis[1] $$saxis[2]";

my $fileNameInput = shift @ARGV;
$fileNameInput = '' unless (defined $fileNameInput);

# Clean/check folder location...
my $info = fileFinder($fileNameInput, {
	'fileMode'			=> 'READ',
	'defaultHandleType'	=> 'FILENAME',
	'defaultName'		=> 'CHGCAR',
});

print ("Info: CHGCARNCL2GRDCOLOUR.pl SAXIS-X SAXIS-Y SAXIS-Z CHGCAR-file\n");
print ("Using $saxis_text\n");

# Read VASP CHGCAR file...
print ("Step 1: Read $$info{'fullPath'}\n");
my $fieldData = CHG2data($$info{'fullPath'});

# Add SAXIS metadata to header
$$fieldData{'header'} = $$fieldData{'header'}." ".$saxis_text;

my $fields = {};

# Separate fields from parent structure
foreach my $fieldName ('field', 'field1', 'field2', 'field3'){
	
	# Check that field is present:
	next unless defined $$fieldData{$fieldName};
	
	# Copy fields to new data structure and then remove from parent --> Create empty structure shell
	$$fields{$fieldName}  = $$fieldData{$fieldName};
	delete $$fieldData{$fieldName};
}

# Write grd file of overall charge density for VESTA
{
	my $vestaGrdFile = $$info{'fullPath'}.'_ALL';
	print ("Step 2: Write total non-spin polarised charge to $vestaGrdFile\n");
	
	my $fieldTemp = dclone ($fieldData);
	die "Missing overall charge density from CHGCAR: Is this CHGCAR complete?" unless defined $$fields{'field'};
	$$fieldTemp{'field'} = $$fields{'field'};
	Data2Grd($vestaGrdFile.'.grd', $fieldTemp);
	Data2CHGCAR($vestaGrdFile, $fieldTemp);
}


# Sum x, y, z fields together
die "Missing charge density spin difference from CHGCAR: Is this CHGCAR spin polarised?" unless defined $$fields{'field1'};
my $fieldTotal;

if (defined ($$fields{'field1'}) && defined ($$fields{'field2'}) && defined ($$fields{'field3'})){

	# Non-collinear CHGCAR - Sum X, Y, Z magnetisation densities together
	$fieldTotal = fieldSum($$fields{'field1'}, $$fields{'field2'}, $$fields{'field3'});

} elsif (defined ($$fields{'field1'}) && !defined ($$fields{'field2'}) && !defined ($$fields{'field3'})){

	# Collinear CHGCAR - Take field1 as magnetisation field
	$fieldTotal = $$fields{'field1'};
	
	# Create some zero fields of same dimensions and move field to 'z' direction
	$$fields{'field1'} = fieldZero($fieldTotal);
	$$fields{'field2'} = fieldZero($fieldTotal);
	$$fields{'field3'} = $fieldTotal;
	
} else {
	die sprintf("Missing charge densities in CHGCAR file - is it complete? Found fields 1-4: %d %d %d %d\n", 
		defined ($$fields{'field'}),
		defined ($$fields{'field1'}),
		defined ($$fields{'field2'}),
		defined ($$fields{'field3'})
	);
}

# Write grd file of summed charge density for VESTA
{
	my $vestaGrdFile = $$info{'fullPath'}.'_MAGTOTAL';
	print ("Step 3: Write summed spin polarised charge to $vestaGrdFile\n");
	
	my $fieldTemp = dclone ($fieldData);
	$$fieldTemp{'field'} = $fieldTotal;
	Data2Grd($vestaGrdFile.'.grd', $fieldTemp);
	Data2CHGCAR($vestaGrdFile, $fieldTemp);
}

# Convert remaining x, y, z fields to vector field:
my $fieldXYZ = fields2vectField($$fields{'field1'}, $$fields{'field2'}, $$fields{'field3'});

# Rotate vector field according to SAXIS setting from VASP
print ("Step 4: Rotate field according to $saxis_text\n");
$fieldXYZ = fieldVectorRotateSAXIS($saxis, $fieldXYZ);

# Write out rotated magnetic moments to x, y, z fields
{
	my ($field1, $field2, $field3) = vectField2fields($fieldXYZ);

	print ("Step 5: Write rotated magnetic vector field to separate files\n");
	{
		my $fieldTemp = dclone ($fieldData);
		$$fieldTemp{'field'} = $field1;
		Data2Grd($$info{'fullPath'}.'_MAGX.grd', $fieldTemp);
		Data2CHGCAR($$info{'fullPath'}.'_MAGX', $fieldTemp);
	}
	{
		my $fieldTemp = dclone ($fieldData);
		$$fieldTemp{'field'} = $field2;
		Data2Grd($$info{'fullPath'}.'_MAGY.grd', $fieldTemp);
		Data2CHGCAR($$info{'fullPath'}.'_MAGY', $fieldTemp);
	}
	{
		my $fieldTemp = dclone ($fieldData);
		$$fieldTemp{'field'} = $field3;
		Data2Grd($$info{'fullPath'}.'_MAGZ.grd', $fieldTemp);
		Data2CHGCAR($$info{'fullPath'}.'_MAGZ', $fieldTemp);
	}
}

# Calculate 'Grad' unit vector field using finite differences --> x("n-1") - x("n+1")
# (Requires UC parameters as well...)
my $fieldTemp = dclone ($fieldData);
$$fieldTemp{'field'} = $$fields{'field'};

print ("Step 6: Take gradient of field (central finite differences, n=2, very slow...)\n");
my $grad = fieldGrad($fieldTemp);

# Calculate dot product of field with normalised gradient --> Colouring output
print ("Step 7: Take unit vector of field\n");
my $gradUnit = fieldVectorUnit($grad);

print ("Step 8: Take Dot product of field\n");
my $colour = fieldVectorDot($gradUnit, $fieldXYZ);

# Write grd file of colour for VESTA
{
	my $vestaGrdFile = $$info{'fullPath'}.'_MAGCOLOUR';
	print ("Step 9: Write colour scalar field to $vestaGrdFile\n");
	
	my $fieldTemp = dclone ($fieldData);
	$$fieldTemp{'field'} = $colour;
	Data2Grd($vestaGrdFile.'.grd', $fieldTemp);
	Data2CHGCAR($vestaGrdFile, $fieldTemp);
}
