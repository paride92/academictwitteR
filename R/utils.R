get_tweets <- function(q="",page_n=500,start_time,end_time,token,next_token="", verbose = TRUE){
  # if(n>500){
  #   warning("n too big. Using 500 instead")
  #   n <- 500
  # }
  # if(n<5){
  #   warning("n too small Using 10 instead")
  #   n <- 500
  # }
  if(missing(start_time)){
    stop("start time must be specified.")
  }
  if(missing(end_time)){
    stop("end time must be specified.")
  }
  if(missing(token)){
    stop("bearer token must be specified.")  
  }
  if(substr(token,1,7)=="Bearer "){
    bearer <- token
  } else{
    bearer <- paste0("Bearer ",token)
  }
  #endpoint
  url <- "https://api.twitter.com/2/tweets/search/all"
  #parameters
  params = list(
    "query" = q,
    "max_results" = page_n,
    "start_time" = start_time,
    "end_time" = end_time, 		
    "tweet.fields" = "attachments,author_id,context_annotations,conversation_id,created_at,entities,geo,id,in_reply_to_user_id,lang,public_metrics,possibly_sensitive,referenced_tweets,source,text,withheld",
    "user.fields" = "created_at,description,entities,id,location,name,pinned_tweet_id,profile_image_url,protected,public_metrics,url,username,verified,withheld",
    "expansions" = "author_id,entities.mentions.username,geo.place_id,in_reply_to_user_id,referenced_tweets.id,referenced_tweets.id.author_id",
    "place.fields" = "contained_within,country,country_code,full_name,geo,id,name,place_type"
  )
  if(next_token!=""){
    params[["next_token"]] <- next_token
  }
  r <- httr::GET(url,httr::add_headers(Authorization = bearer),query=params)
  
  #fix random 503 errors
  count <- 0
  while(httr::status_code(r)==503 & count<4){
    r <- httr::GET(url,httr::add_headers(Authorization = bearer),query=params)
    count <- count+1
    Sys.sleep(count*5)
  }
  if(httr::status_code(r)==429){
    .vcat(verbose, "Rate limit reached, sleeping... \n")
    Sys.sleep(900)
    r <- httr::GET(url,httr::add_headers(Authorization = bearer),query=params)
  }
  
  if(httr::status_code(r)!=200){
    stop(paste("something went wrong. Status code:", httr::status_code(r)))
  }
  if(httr::headers(r)$`x-rate-limit-remaining`=="1"){
    .vwarn(verbose, paste("x-rate-limit-remaining=1. Resets at",as.POSIXct(as.numeric(httr::headers(r)$`x-rate-limit-reset`), origin="1970-01-01")))
  }
  dat <- jsonlite::fromJSON(httr::content(r, "text"))
  dat
}

fetch_data <- function(built_query, data_path, file, bind_tweets, start_tweets, end_tweets, bearer_token = get_bearer(), n, page_n, verbose){
  nextoken <- ""
  df.all <- data.frame()
  toknum <- 0
  ntweets <- 0
  while (!is.null(nextoken)) {
    df <-
      get_tweets(
        q = built_query,
        page_n = page_n,
        start_time = start_tweets,
        end_time = end_tweets,
        token = bearer_token,
        next_token = nextoken
      )
    if (is.null(data_path)) {
      # if data path is null, generate data.frame object within loop
      df.all <- dplyr::bind_rows(df.all, df$data)
    }

    if (!is.null(data_path) & is.null(file) & bind_tweets == F) {
      df_to_json(df, data_path)
    }
    if (!is.null(data_path)) {
      df_to_json(df, data_path)
      df.all <-
        dplyr::bind_rows(df.all, df$data) #and combine new data with old within function
    }
    
    nextoken <-
      df$meta$next_token #this is NULL if there are no pages left
    toknum <- toknum + 1
    if (is.null(df$data)) {
      n_newtweets <- 0
    } else {
      n_newtweets <- nrow(df$data)
    }
    ntweets <- ntweets + n_newtweets
    .vcat(verbose, 
        "query: <",
        built_query,
        ">: ",
        "(tweets captured this page: ",
        n_newtweets,
        "). Total pages queried: ",
        toknum,
        ". Total tweets ingested: ",
        ntweets, 
        ". \n",
        sep = ""
        )
    if (ntweets > n){ # Check n
      df.all <- df.all[1:n,] # remove extra
      .vcat(verbose, "Total tweets ingested now exceeds ", n, ": finishing collection.\n")
      break
    }
    if (is.null(nextoken)) {
      .vcat(verbose, "This is the last page for", built_query, ": finishing collection.\n")
      break
    }
  }
  
  if (is.null(data_path) & is.null(file)) {
    return(df.all) # return to data.frame
  }
  if (!is.null(file)) {
    saveRDS(df.all, file = file) # save as RDS
    return(df.all) # return data.frame
  }
  
  if (!is.null(data_path) & bind_tweets==T) {
    return(df.all) # return data.frame
  }
  
  if (!is.null(data_path) &
      is.null(file) & bind_tweets == F) {
    .vcat(verbose, "Data stored as JSONs: use bind_tweets function to bundle into data.frame")
  }
}

check_bearer <- function(bearer_token){
  if(missing(bearer_token)){
    stop("bearer token must be specified.")
  }
  if(substr(bearer_token,1,7)=="Bearer "){
    bearer <- bearer_token
  } else{
    bearer <- paste0("Bearer ",bearer_token)
  }
  return(bearer)
}

check_data_path <- function(data_path, file, bind_tweets, verbose = TRUE){
  #warning re data storage recommendations if no data path set
  if (is.null(data_path)) {
    .vwarn(verbose, "Recommended to specify a data path in order to mitigate data loss when ingesting large amounts of data.")
  }
  #warning re data.frame object and necessity of assignment
  if (is.null(data_path) & is.null(file)) {
    .vwarn(verbose, "Tweets will not be stored as JSONs or as a .rds file and will only be available in local memory if assigned to an object.")
  }
  #stop clause for if user sets bind_tweets to FALSE but sets no data path
  if (is.null(data_path) & bind_tweets == F) {
    stop("Argument (bind_tweets = F) only valid when a data_path is specified.")
  }
  #warning re binding of tweets when a data path and file path have been set but bind_tweets is set to FALSE
  if (!is.null(data_path) & !is.null(file) & bind_tweets == F) {
    .vwarn(verbose, "Tweets will still be bound in local memory to generate .rds file. Argument (bind_tweets = F) only valid when just a data path has been specified.")
  }
  #warning re data storage and memory limits when setting bind_tweets to TRUE 
  if (!is.null(data_path) & is.null(file) & bind_tweets == T) {
    .vwarn(verbose, "Tweets will be bound in local memory as well as stored as JSONs.")
  }
}

create_data_dir <- function(data_path, verbose = TRUE){
  #create folders for storage
  if (dir.exists(file.path(data_path))) {
    .vwarn(verbose, "Directory already exists. Existing JSON files may be parsed and returned, choose a new path if this is not intended.")
    invisible(data_path)
  }
  dir.create(file.path(data_path), showWarnings = FALSE)
    invisible(data_path)  
}

df_to_json <- function(df, data_path){
  # check input
  # if data path is supplied and file name given, generate data.frame object within loop and JSONs
  jsonlite::write_json(df$data,
                       paste0(data_path, "data_", df$data$id[nrow(df$data)], ".json"))
  jsonlite::write_json(df$includes,
                       paste0(data_path, "users_", df$data$id[nrow(df$data)], ".json"))
}

create_storage_dir <- function(data_path, export_query, built_query, start_tweets, end_tweets, verbose){
  if (!is.null(data_path)){
    create_data_dir(data_path, verbose)
    if (isTRUE(export_query)){ # Note export_query is called only if data path is supplied
      # Writing query to file (for resuming)
      filecon <- file(paste0(data_path,"query"))
      writeLines(c(built_query,start_tweets,end_tweets), filecon)
      close(filecon)
    }
  }
}


.gen_random_dir <- function() {
  paste0(tempdir(), "/", paste0(sample(letters, 20), collapse = ""))
}

.vcat <- function(bool, ...) {
  if (bool) {
    cat(...)
  }
}

.vwarn <- function(bool, ...) {
  if (bool) {
    warning(..., call. = FALSE)
  }
}

.process_qparam <- function(param, param_str,query) {
  if(!is.null(param)){
    if(isTRUE(param)) {
      query <- paste(query, param_str)
    } else if(param == FALSE) {
      query <- paste(query, paste0("-", param_str))
    }
  }
  return(query)
}
