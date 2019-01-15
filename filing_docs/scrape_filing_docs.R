#!/usr/bin/env Rscript
library(dplyr, warn.conflicts = FALSE)
library(DBI)
library(rvest, quietly = TRUE)

get_index_url <- function(file_name) {
    matches <- stringr::str_match(file_name, "/(\\d+)/(\\d{10}-\\d{2}-\\d{6})")
    cik <- matches[2]
    acc_no <- matches[3]
    path <- stringr::str_replace_all(acc_no, "[^\\d]", "")

    url <- paste0("https://www.sec.gov/Archives/edgar/data/", cik, "/", path, "/",
                  acc_no, "-index.htm")
    return(url)
}

fix_names <- function(df) {
    colnames(df) <- tolower(colnames(df))
    df
}

get_filing_docs <- function(file_name) {

     head_url <- get_index_url(file_name)

     table_nodes <-
         try({
             read_html(head_url, encoding="Latin1") %>%
                 html_nodes("table")
         })

     if (length(table_nodes) < 1 | is(table_nodes, "try-error")) {
         df <- tibble(seq = NA, description = NA, document = NA, type = NA,
                      size = NA, file_name = file_name)
         return(df)
     } else {

         df <-
             table_nodes[1] %>%
             html_table() %>%
             bind_rows() %>%
             fix_names() %>%
             mutate(file_name = file_name,
                    type = as.character(type))
         df
     }

    df
}

pg <- dbConnect(RPostgres::Postgres())

rs <- dbExecute(pg, "SET work_mem = '5GB'")
rs <- dbExecute(pg, "SET search_path TO edgar, public")

filings <- tbl(pg, "filings")

def14_a <-
    filings %>%
    # filter(form_type %~% "^(10-[QK]|SC 13[DG](/A)?|DEF 14|8-K|6-K|13|[345](/A)?$)") %>%
    select(file_name)

new_table <- !dbExistsTable(pg, "filing_docs")

if (!new_table) {
    filing_docs <- tbl(pg, "filing_docs")
    def14_a <- def14_a %>% anti_join(filing_docs, by = "file_name")
}

get_file_names <- function() {
    def14_a %>%
    collect(n = 1000)
}

library(parallel)

batch <- 0
while(nrow(file_names <- get_file_names()) > 0) {
    batch <- batch + 1
    cat("Processing batch", batch, "\n")
    temp <- mclapply(file_names$file_name, get_filing_docs, mc.cores = 6)
    if (length(temp) > 0) {
        df <- bind_rows(temp)

        if (nrow(df) > 0) {
            cat("Writing data ...\n")
            dbWriteTable(pg, "filing_docs",
                         df, append = TRUE, row.names = FALSE)

        } else {
            cat("No data ...\n")
        }
    }
}

if (new_table) {
    pg <- dbConnect(RPostgres::Postgres())

    rs <- dbExecute(pg, "SET search_path TO edgar, public")
    rs <- dbExecute(pg, "CREATE INDEX ON filing_docs (file_name)")
    rs <- dbExecute(pg, "ALTER TABLE filing_docs OWNER TO edgar")
    rs <- dbExecute(pg, "GRANT SELECT ON TABLE filing_docs TO edgar_access")

    rs <- dbDisconnect(pg)
}

temp <- unlist(temp)