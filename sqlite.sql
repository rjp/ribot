CREATE TABLE url (
    plop date,
    url varchar(1024),
    comment varchar(1024),
    wh timestamp DEFAULT CURRENT_TIMESTAMP, 
    userby varchar(256),
    id integer primary key autoincrement,
    idnum integer,
    private integer DEFAULT 0,
    title varchar(1024),
    cache bytea,
    cache_url varchar(1024),
    source varchar(256),
    submitter varchar(256),
    thcreated timestamp ,
    urlmodified timestamp ,
    alive timestamp 
);
