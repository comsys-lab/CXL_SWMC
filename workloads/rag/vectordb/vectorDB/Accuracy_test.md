accuracy test를 하기 위해서는, common crawl이 insert 된 flat_index와 indexbin 내의 deleted.bin 파일들이 필요함.
그걸 위해서는 bulk_delete_insert.py를 이용해서 260K, 520K, 780K, 1040K 개의 vector를 insert 해야하고, 그 후에, 260K, 520K, 780K, 1040K 개의 vector를 delete 해야함.

260K개의 vecter를 insert하고 delete하는걸 한 다음에, vectorDB를 정상적으로 종료하고 해당 파일을 따로 저장한 뒤에, 다시 켜서 260K개의 vector를 insert 하고 delete 하는걸 추가하는 방식으로 진행하면 됨.

이후 GPU 서버에서 PubMed로 0~26020202 까지 chunk_id를 넣고, 26020203~28000000까지의 chunk_id는 Common Crawl로 넣어서 SQLite를 만들어놓으면 됨.