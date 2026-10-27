"""Read committed RGBA PNG alpha for resource geometry tests; no image edits."""
import struct,zlib
from pathlib import Path

def rgba(p):
 b=p.read_bytes();w,h,depth,kind,*_=struct.unpack('>IIBBBBB',b[16:29]);assert(depth,kind)==(8,6)
 pos=8;packed=b''
 while pos<len(b):
  size=struct.unpack('>I',b[pos:pos+4])[0]
  if b[pos+4:pos+8]==b'IDAT':packed+=b[pos+8:pos+8+size]
  pos+=size+12
 d=zlib.decompress(packed);pos=0;prev=bytearray(w*4);rows=[]
 for y in range(h):
  f=d[pos];pos+=1;r=bytearray(d[pos:pos+w*4]);pos+=w*4
  for x in range(len(r)):
   a=r[x-4] if x>=4 else 0;c=prev[x-4] if x>=4 else 0;v=prev[x]
   if f==1:q=a
   elif f==2:q=v
   elif f==3:q=(a+v)//2
   elif f==4:
    k=a+v-c;ds=[abs(k-a),abs(k-v),abs(k-c)];q=[a,v,c][ds.index(min(ds))]
   else:q=0
   r[x]=(r[x]+q)&255
  rows.append(r);prev=r
 return w,h,rows
