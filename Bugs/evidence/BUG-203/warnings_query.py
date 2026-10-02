import sqlite3,sys
db=sys.argv[1]; srcs=sys.argv[2:]
c=sqlite3.connect(db)
for r in c.execute("select id,ts,source,key,level,substr(text,1,60),shown from warnings where source in (%s) order by id"%",".join("?"*len(srcs)),srcs): print(r)
