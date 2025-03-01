#' @title
#' Extract longitudinal REDCap databases into tidy tibbles
#'
#' @description
#' Helper function internal to \code{read_redcap_tidy} responsible for
#' extraction and final processing of a tidy \code{tibble} to the user from
#' a longitudinal REDCap database.
#'
#' @param db_data_long The longitudinal REDCap database output defined by
#' \code{REDCapR::redcap_read_oneshot()$data}
#' @param db_metadata_long The longitudinal REDCap metadata output defined by
#' \code{REDCapR::redcap_metadata_read()$data}
#' @param linked_arms Output of \code{link_arms}, linking forms to REDCap
#' events/arms
#'
#' @return
#' Returns a \code{tibble} with list elements containing tidy dataframes. Users
#' can access dataframes under the \code{redcap_data} column with reference to
#' \code{form_name} and \code{structure} column details.
#'
#' @importFrom checkmate assert_data_frame
#' @importFrom dplyr filter pull
#' @importFrom purrr map
#' @importFrom tibble tibble
#' @importFrom rlang .data
#'
#' @keywords internal

clean_redcap_long <- function(
    db_data_long,
    db_metadata_long,
    linked_arms
) {

  # Repeating Instrument Check ----
  # Check if database supplied contains any repeating instruments to map onto
  # `redcap_repeat_*` variables

  has_repeating <- if ("redcap_repeat_instance" %in% names(db_data_long)) {
    TRUE
  } else {
    FALSE
  }

  # Apply checkmate checks
  assert_data_frame(db_data_long)
  assert_data_frame(db_metadata_long)

  if (has_repeating) {
    check_repeat_and_nonrepeat(db_data_long)
  }

  ## Repeating Forms Logic ----
  if (has_repeating) {
    repeated_forms <- db_data_long %>%
      filter(!is.na(.data$redcap_repeat_instrument)) %>%
      pull(.data$redcap_repeat_instrument) %>%
      unique()

    repeated_forms_tibble <- tibble(
      redcap_form_name = repeated_forms,
      redcap_data = map(
        .data$redcap_form_name,
        ~ distill_repeat_table_long(.x,
                                    db_data_long,
                                    db_metadata_long,
                                    linked_arms)
      ),
      structure = "repeating"
    )
  }

  ## Nonrepeating Forms Logic ----
  nonrepeated_forms <- db_metadata_long %>%
    pull(.data$form_name) %>%
    unique()

  if (has_repeating) {
    nonrepeated_forms <- setdiff(nonrepeated_forms,
                                 repeated_forms)
  }

  nonrepeated_forms_tibble <- tibble(
    redcap_form_name = nonrepeated_forms,
    redcap_data = map(
      .data$redcap_form_name,
      ~ distill_nonrepeat_table_long(.x,
                                     db_data_long,
                                     db_metadata_long,
                                     linked_arms)
    ),
    structure = "nonrepeating"
  )

  if (has_repeating) {
    rbind(repeated_forms_tibble, nonrepeated_forms_tibble)
  } else {
    nonrepeated_forms_tibble
  }
}

#' @title
#' Extract non-repeat tables from longitudinal REDCap databases
#'
#' @description
#' Sub-helper function to \code{clean_redcap_long} for single nonrepeat table
#' extraction.
#'
#' @return
#' A \code{tibble} of all data related to a specified \code{form_name}
#'
#' @param form_name The \code{form_name} described in the named column from the
#' REDCap metadata.
#' @param db_data_long The REDCap database output defined by
#' \code{REDCapR::redcap_read_oneshot()$data}
#' @param db_metadata_long The REDCap metadata output defined by \code{REDCapR::redcap_metadata_read()$data}
#' @param linked_arms Output of \code{link_arms}, linking forms to REDCap
#' events/arms
#'
#' @importFrom dplyr filter pull select relocate rename
#' @importFrom tidyselect all_of everything
#' @importFrom tibble tibble
#' @importFrom stringr str_detect
#' @importFrom rlang .data
#'
#' @keywords internal

distill_nonrepeat_table_long <- function(
    form_name,
    db_data_long,
    db_metadata_long,
    linked_arms
) {
  # Repeating Instrument Check ----
  # Check if database supplied contains any repeating instruments to map onto
  # `redcap_repeat_*` variables
  has_repeating <- if ("redcap_repeat_instance" %in% names(db_data_long)) {
    TRUE
  } else {
    FALSE
  }

  my_record_id <- names(db_data_long)[1]
  my_form <- form_name

  my_fields <- db_metadata_long %>%
    filter(.data$form_name == my_form) %>%
    pull(.data$field_name_updated)

  if (my_fields[1] != my_record_id) {
    my_fields <- c(my_record_id, all_of(my_fields))
  }

  # Below necessary to remove descriptive text fields
  # and to add column to indicate that form is completed
  my_fields <- db_data_long %>%
    select(all_of(my_fields), paste0(my_form, "_complete")) %>%
    names()

  # Setup data for loop redcap_arm linking
  db_data_long <- db_data_long %>%
    add_partial_keys()

  if (has_repeating) {
    db_data_long <- db_data_long %>%
      filter(is.na(.data$redcap_repeat_instance))
  }

  # Use link_arms() output to check if my_form appears in each event_name
  # If it does not, filter out all rows containing that event_name
  for (i in seq_along(names(linked_arms))) {
    if (my_form %in% unlist(linked_arms[[i]]) == FALSE) {
      db_data_long <- db_data_long %>%
        filter(.data$redcap_event_name != names(linked_arms[i]))
    }
    db_data_long
  }

  # Final aesthetic cleanup
  out <- db_data_long %>%
    select(all_of(my_fields), .data$redcap_event, .data$redcap_arm) %>%
    relocate(
      c(.data$redcap_event, .data$redcap_arm), .after = !!my_record_id
    ) %>%
    rename("form_status_complete" = paste0(my_form, "_complete")) %>%
    relocate(.data$form_status_complete, .after = everything())

  # Remove arms column if necessary
  if (!any(names(linked_arms) %>% str_detect("arm_2"))) {
    out <- out %>%
      select(-.data$redcap_arm)
  }

  out %>%
    tibble()
}

#' @title
#' Extract repeat tables from longitudinal REDCap databases
#'
#' @description
#' Sub-helper function to \code{clean_redcap_long} for single repeat table
#' extraction.
#'
#' @return
#' A \code{tibble} of all data related to a specified \code{form_name}
#'
#' @param form_name The \code{form_name} described in the named column from the
#' REDCap metadata.
#' @param db_data_long The REDCap database output defined by
#' \code{REDCapR::redcap_read_oneshot()$data}
#' @param db_metadata_long The REDCap metadata output defined by
#' \code{REDCapR::redcap_metadata_read()$data}
#' @param linked_arms Output of \code{link_arms}, linking forms to REDCap
#' events/arms
#'
#' @importFrom dplyr filter pull select relocate rename
#' @importFrom tidyselect all_of everything
#' @importFrom tibble tibble
#' @importFrom stringr str_detect
#' @importFrom rlang .data
#' @keywords internal

distill_repeat_table_long <- function(
    form_name,
    db_data_long,
    db_metadata_long,
    linked_arms
) {
  my_record_id <- names(db_data_long)[1]
  my_form <- form_name

  my_fields <- db_metadata_long %>%
    filter(.data$form_name == my_form) %>%
    pull(.data$field_name_updated)

  if (my_fields[1] != my_record_id) {
    my_fields <- c(my_record_id, all_of(my_fields))
  }

  # Below necessary to remove descriptive text fields
  # and to add column to indicate that form is completed
  my_fields <- db_data_long %>%
    select(all_of(my_fields), paste0(my_form, "_complete")) %>%
    names()

  # Setup data for loop redcap_arm linking
  db_data_long <- db_data_long %>%
    add_partial_keys() %>%
    filter(
      !is.na(.data$redcap_repeat_instance) &
        .data$redcap_repeat_instrument == my_form
    )

  # Use link_arms() output to check if my_form appears in each event_name
  # If it does not, filter out all rows containing that event_name
  for (i in seq_along(names(linked_arms))) {
    if (my_form %in% unlist(linked_arms[[i]]) == FALSE) {
      db_data_long <- db_data_long %>%
        filter(.data$redcap_event_name != names(linked_arms[i]))
    }
    db_data_long
  }

  # Final aesthetic cleanup
  out <- db_data_long %>%
    filter(.data$redcap_repeat_instrument == my_form) %>%
    select(
      all_of(my_fields),
      .data$redcap_repeat_instance, .data$redcap_event, .data$redcap_arm
    ) %>%
    relocate(
      c(.data$redcap_repeat_instance,
        .data$redcap_event,
        .data$redcap_arm),
      .after = !!my_record_id
    ) %>%
    rename("form_status_complete" = paste0(my_form, "_complete")) %>%
    relocate(.data$form_status_complete, .after = everything())

  # Remove arms column if necessary
  if (!any(names(linked_arms) %>% str_detect("arm_2"))) {
    out <- out %>%
      select(-.data$redcap_arm)
  }

  out %>%
    tibble()
}
