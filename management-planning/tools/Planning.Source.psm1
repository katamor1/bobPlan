Set-StrictMode -Version 2.0
function Read-MpXlsxSource {
 param([string]$Path,[string]$Sheet,[string]$Range)
 if([IO.Path]::GetExtension($Path) -ine '.xlsx'){throw 'Source must be .xlsx'}
 if($Range -notmatch '^\$?([A-Z]{1,3})\$?([1-9]\d*)(?::\$?([A-Z]{1,3})\$?([1-9]\d*))?$'){throw 'Source range must use A1 notation.'}
 function ColNumber($s){$n=0;foreach($ch in $s.ToCharArray()){$n=$n*26+([int]$ch-64)};return $n}
 $left=ColNumber $Matches[1];$top=[int]$Matches[2];$right=$left;$bottom=$top
 if($Matches[3]){$right=ColNumber $Matches[3];$bottom=[int]$Matches[4]}
 if($left -gt $right -or $top -gt $bottom -or $right -gt 16384 -or $bottom -gt 1048576 -or ([long]($right-$left+1)*($bottom-$top+1)) -gt 100000){throw 'Invalid or oversized source range (maximum 100000 cells).'}
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $zip=[IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
 function XmlPart($name){
  $entry=$zip.GetEntry($name);if($null -eq $entry){throw "XLSX part missing: $name"}
  $settings=New-Object Xml.XmlReaderSettings;$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
  $stream=$entry.Open();$reader=[Xml.XmlReader]::Create($stream,$settings)
  try{$xml=New-Object Xml.XmlDocument;$xml.XmlResolver=$null;$xml.Load($reader);return $xml}finally{$reader.Dispose();$stream.Dispose()}
 }
 try{
  $book=XmlPart 'xl/workbook.xml';$relations=XmlPart 'xl/_rels/workbook.xml.rels'
  $sheetNode=@($book.SelectNodes('//*[local-name()="sheet"]') | Where-Object {$_.GetAttribute('name') -ceq $Sheet})
  if($sheetNode.Count -ne 1){throw "Source sheet not found: $Sheet"}
  $id=$sheetNode[0].GetAttribute('id','http://schemas.openxmlformats.org/officeDocument/2006/relationships')
  $rel=@($relations.SelectNodes('//*[local-name()="Relationship"]') | Where-Object {$_.GetAttribute('Id') -ceq $id})
  if($rel.Count -ne 1 -or $rel[0].GetAttribute('TargetMode') -eq 'External'){throw 'Invalid worksheet relationship.'}
  $target=$rel[0].GetAttribute('Target')
  if($target.StartsWith('/')){$part=$target.TrimStart('/')}else{$uri=New-Object Uri((New-Object Uri('https://package.invalid/xl/')),$target);$part=$uri.AbsolutePath.TrimStart('/')}
  if(-not $part.StartsWith('xl/')){throw 'Worksheet part outside xl/.'}
  $sheetXml=XmlPart $part;$strings=@()
  if($null -ne $zip.GetEntry('xl/sharedStrings.xml')){$sst=XmlPart 'xl/sharedStrings.xml';$strings=@($sst.SelectNodes('//*[local-name()="si"]') | ForEach-Object {(@($_.SelectNodes('.//*[local-name()="t"]') | ForEach-Object InnerText) -join '')})}
  foreach($cell in $sheetXml.SelectNodes('//*[local-name()="sheetData"]/*[local-name()="row"]/*[local-name()="c"]')){
   $address=$cell.GetAttribute('r')
   if($address -notmatch '^([A-Z]+)([1-9]\d*)$'){continue}
   $c=ColNumber $Matches[1];$r=[int]$Matches[2]
   if($c -lt $left -or $c -gt $right -or $r -lt $top -or $r -gt $bottom){continue}
   $value=$cell.SelectSingleNode('./*[local-name()="v"]');$formula=$cell.SelectSingleNode('./*[local-name()="f"]')
   if($null -ne $formula -and $null -eq $value){throw "Formula has no saved result: $Sheet!$address. Recalculate and save a copy in Excel."}
   $text=''
   switch($cell.GetAttribute('t')){
    's' {if($null -eq $value -or [int]$value.InnerText -ge $strings.Count){throw "Invalid shared string: $address"};$text=$strings[[int]$value.InnerText]}
    'inlineStr' {$text=(@($cell.SelectNodes('.//*[local-name()="t"]') | ForEach-Object InnerText) -join '')}
    'e' {throw ('Excel error value at '+$Sheet+'!'+$address+': '+$value.InnerText)}
    default {if($null -ne $value){$text=$value.InnerText}}
   }
   if($text -ne ''){[pscustomobject]@{Anchor=$Sheet+'!'+$address;Text=$text}}
  }
 }finally{$zip.Dispose()}
}
Export-ModuleMember -Function Read-MpXlsxSource
