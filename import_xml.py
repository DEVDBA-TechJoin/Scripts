import psycopg2
import os
import zlib

output_dir = os.path.expanduser("~/xmls")
os.makedirs(output_dir, exist_ok=True)

conn = psycopg2.connect(
    host="2559-07799",
    dbname="drogamaxpopular_esc_20241107",
    user="chinchila",
    password="chinchila"
)
cur = conn.cursor()

# Buscar o nome e o OID do arquivo (XML)
cur.execute("""
SELECT arquivo.nome, arquivo.arquivo
FROM venda
JOIN nfe ON nfe.vendaid = venda.id
LEFT JOIN orcamento ON orcamento.id = venda.orcamentoId
JOIN orcamentoPbm ON orcamentoPbm.orcamentoId = orcamento.id 
LEFT JOIN pbm ON pbm.id = orcamentoPbm.pbmid
LEFT JOIN arquivo ON nfe.arquivoXMLId = arquivo.id
WHERE orcamentoPbm.pbmid = 349 
  AND venda.status = 'F'
  AND venda.unidadenegocioid = 73108
  AND venda.coo IN (
    '018735','031244','033806','026181','025922','025517','030429','017348','030265','032008',
    '030163','031796','016952','029969','024728','031398','031379','031377','024600','031023',
    '029092','029049','023441','023289','029532','023173','023033','023016','015100','022943',
    '022727','022282','022250','022246','022175','022041','021840','013259','020979','020567',
    '026104','020284','019490','018974','011134','011103','018617','023761','017842','017818',
    '010043','017055','009696','009113','020488','008594','008128','013994','013492','007887',
    '012585','006740','014157','006644','014752','006503','010525','006319','013192','006255',
    '006247','006211','006177','009717','005918','013290','011909','011888','009153','009061',
    '012134','005085','010509','010414','007978','007848','010278','009820','004383','004333',
    '009323','004016','005931','005817','005725','005668','005605','007414','006827','002980',
    '004419','006177','005763','002667','002476','002408','002407','002283','004286','003133',
    '002896','003565','002761','002750','003333','001542','002362','002295','001369','002205',
    '002108','001979','002180','001204','001698','001597','001559','001550','001458','001455',
    '001437','001365','001282','000770','000466','000686','000362','000330','000460','000468',
    '000346','000279','000205'
  );
""")

for nome, oid in cur.fetchall():
    if oid is None:
        print(f"[!] Ignorado: {nome} — XML não encontrado")
        continue
    try:
        lobj = conn.lobject(oid, 'rb')  # rb = read binary
        compressed_xml_data = lobj.read()
        lobj.close()
        
        # Tentar descompactar com zlib
        try:
            xml_data = zlib.decompress(compressed_xml_data)
        except zlib.error as e:
            print(f"[✗] Erro de descompressão zlib para {nome}: {e}. Tentando salvar como está.")
            xml_data = compressed_xml_data # Se falhar, tenta salvar o original

        nome_arquivo = nome if nome.endswith(".xml") else nome + ".xml"
        with open(os.path.join(output_dir, nome_arquivo), "wb") as f:
            f.write(xml_data)
        print(f"[✓] XML salvo: {nome_arquivo}")
    except Exception as e:
        print(f"[✗] Erro ao salvar {nome}: {e}")

cur.close()
conn.close()

