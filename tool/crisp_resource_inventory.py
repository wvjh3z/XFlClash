"""Derive exact runtime names and R identifiers from the pinned public AAR."""
import hashlib
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile


def inventory(aar, expected_sha256):
    aar=Path(aar)
    if hashlib.sha256(aar.read_bytes()).hexdigest()!=expected_sha256:
        raise ValueError('Crisp AAR checksum mismatch')
    with zipfile.ZipFile(aar) as archive:
        identifiers=set()
        for line in archive.read('R.txt').decode('utf-8').splitlines():
            f=line.split()
            if len(f)!=4 or f[0]!='int' or f[2]=='crisp_sdk_keep':continue
            if (f[1] in ('bool','color','drawable','raw','string') and f[2].startswith('crisp_')) or (f[1]=='style' and f[2].startswith('Theme_Crisp_')):
                identifiers.add(f[1]+'/'+f[2])
        names={key:set() for key in identifiers}
        def add(kind,name):
            key=kind+'/'+name.replace('.','_')
            if key in names:names[key].add(name)
        for path in archive.namelist():
            if path.startswith('res/values') and path.endswith('.xml'):
                for element in ET.fromstring(archive.read(path)):
                    name=element.get('name')
                    kind=element.get('type') if element.tag=='item' else element.tag
                    if name and kind:add(kind,name)
            elif path.startswith('res/') and not path.endswith('/'):
                parts=path.split('/')
                if len(parts)==3:
                    kind=parts[1].split('-')[0]
                    # File resource extensions are not part of the runtime name.
                    filename=parts[2]
                    name=filename[:-6] if filename.endswith('.9.png') else filename.rsplit('.',1)[0]
                    add(kind,name)
        if not names or any(len(value)!=1 for value in names.values()):
            raise ValueError('Missing or ambiguous Crisp runtime resource mapping')
        return {key:next(iter(value)) for key,value in sorted(names.items())}
