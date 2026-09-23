#!/usr/bin/env Rscript
# DOC
#
# Score specific models' forecasts using the same metrics, relative-skill
# baseline, and scale transform as the dashboard (see predevals-config.yml),
# without running the full hubPredEvalsData-docker pipeline (which scores
# every model across every target/eval_set/disaggregation and is slow) or
# rebuilding the site.
#
# Reuses hubPredEvalsData's own internal scoring helpers, so the numbers
# match what the dashboard would show exactly (same hubEvals::score_model_out
# call, same transform, same baseline) -- just restricted to the model(s),
# target, and eval_set you ask for.
#
# USAGE
#
#   Rscript src/score_models.R -m <model_ids> [-t <target_id>] \
#     [-e <eval_set_name>] [-b <by>] [-h <hub_path>] [-c <config_path>] \
#     [-o <out_dir>]
#
# ARGUMENTS
#
#   --help                print help and exit
#   -m <model_ids>        comma-separated model_id(s) to score (required)
#   -t <target_id>        target_id to score (default: all targets in config)
#   -e <eval_set_name>    eval_set_name to score (default: all eval_sets in
#                         config)
#   -b <by>               a single disaggregate_by column (e.g. "location"),
#                         or omit for the overall (non-disaggregated) summary
#   -h <hub_path>         path to the hub (default: ../forecast-sandbox-2025-2026,
#                         i.e. the sibling hub checkout)
#   -c <config_path>      path to predevals-config.yml (default:
#                         predevals-config.yml, i.e. the dashboard repo root)
#   -o <out_dir>          if given, also write scores.csv files under this
#                         directory, mirroring data/evals/scores/ layout.
#                         Without it, results are only printed to the console.
#
# NOTE ON PACKAGE VERSIONS
#
#   This calls hubData/hubEvals/hubPredEvalsData installed in your local R
#   library, which may not exactly match the versions pinned in
#   ghcr.io/hubverse-org/hubpredevalsdata-docker (the image the dashboard's
#   real data-generation pipeline uses). In testing, wis/ae_median/
#   interval_coverage_* matched the dashboard's checked-in scores exactly,
#   but the `n` column was off by a few rows due to a hubData version
#   difference (2.1.0 local vs. 2.2.2 in the pinned image at the time of
#   writing) -- likely a difference in how a count/metadata field is
#   computed, not in which forecast tasks got scored. If you need
#   byte-for-byte parity, install the exact versions from
#   hubPredEvalsData-docker/renv.lock instead of GitHub HEAD.
#
# NOTE ON RELATIVE SKILL
#
#   wis, ae_median, and interval_coverage_* are computed per model
#   independently, so they will exactly match the full dashboard regardless
#   of which other models you include here. wis_scaled_relative_skill and
#   ae_median_scaled_relative_skill are PAIRWISE comparisons across every
#   model in the eval set, so they only exactly match the dashboard if you
#   request the same full set of models used there. The target's configured
#   baseline model is always pulled in automatically (even if you didn't ask
#   for it) so relative skill can be computed at all; a note is printed when
#   that happens.
#
# EXAMPLE
#
#   Rscript src/score_models.R -m "FluSight-baseline,UMass-AR2" \
#     -t "wk inc flu hosp" -e "2025-2026 season, US national level"
#
# DOC

args <- commandArgs()

print_help <- function(script) {
  lines <- readLines(script)
  bookends <- which(lines == "# DOC")
  writeLines(sub(
    "# ?",
    "",
    lines[(bookends[1] + 1):(bookends[2] - 1)],
    perl = TRUE
  ))
  quit(save = "no", status = 0)
}

parse_args <- function(args, flag) {
  if (any(args == "--help")) {
    script <- sub("--file=", "", args[startsWith(args, "--file")], fixed = TRUE)
    print_help(script)
  }
  value <- args[which(args == flag) + 1]
  if (length(value) == 0 || is.na(value)) NULL else value
}

model_ids_arg <- parse_args(args, "-m")
target_arg <- parse_args(args, "-t")
eval_set_arg <- parse_args(args, "-e")
by_arg <- parse_args(args, "-b")
hub_path_arg <- parse_args(args, "-h")
config_arg <- parse_args(args, "-c")
out_dir_arg <- parse_args(args, "-o")

if (is.null(model_ids_arg)) {
  stop("`-m <model_ids>` is required. Run with --help for usage.")
}

hub_path <- hub_path_arg %||% "../forecast-sandbox-2025-2026"
config_path <- config_arg %||% "predevals-config.yml"
model_ids <- trimws(strsplit(model_ids_arg, ",")[[1]])

config <- hubPredEvalsData:::read_predevals_config(hub_path, config_path)

targets <- config$targets
if (!is.null(target_arg)) {
  targets <- Filter(function(t) t$target_id == target_arg, targets)
  if (length(targets) == 0) {
    stop("target_id '", target_arg, "' not found in ", config_path)
  }
}

hub_con <- hubData::connect_hub(hub_path)
oracle_output <- dplyr::collect(hubData::connect_target_oracle_output(hub_path))
oracle_output$as_of <- NULL

write_to_disk <- !is.null(out_dir_arg)
out_path <- out_dir_arg %||% tempfile("score_models_")
dir.create(out_path, recursive = TRUE, showWarnings = FALSE)

for (target in targets) {
  target_id <- target$target_id
  baseline <- target$baseline
  relative_metrics <- target$relative_metrics
  transform <- hubPredEvalsData:::resolve_target_transform(target, config$transform_defaults)
  task_groups_w_target <- hubPredEvalsData:::get_task_groups_w_target(hub_path, target_id, config$rounds_idx)
  metric_name_to_output_type <- hubPredEvalsData:::get_metric_name_to_output_type(task_groups_w_target, target$metrics)
  oracle_output_t <- hubPredEvalsData:::filter_to_target(oracle_output, task_groups_w_target)

  eval_sets <- config$eval_sets
  if (!is.null(eval_set_arg)) {
    eval_sets <- Filter(function(e) e$eval_set_name == eval_set_arg, eval_sets)
    if (length(eval_sets) == 0) {
      stop("eval_set_name '", eval_set_arg, "' not found in ", config_path)
    }
  }

  needed_models <- model_ids
  if (length(relative_metrics) > 0 && !(baseline %in% model_ids)) {
    needed_models <- union(model_ids, baseline)
    message(
      "Note: baseline model '", baseline, "' for target '", target_id,
      "' was not requested but is auto-included so relative skill can be computed."
    )
  }

  for (eval_set in eval_sets) {
    model_out_tbl <- hubPredEvalsData:::load_model_out_in_eval_set(
      hub_path, target_id, eval_set, config$rounds_idx,
      hub_con = hub_con
    )
    if (nrow(model_out_tbl) == 0) {
      message(
        "No model output data found for target '", target_id,
        "' in evaluation set '", eval_set$eval_set_name, "'."
      )
      next
    }
    model_out_tbl <- dplyr::filter(model_out_tbl, .data[["model_id"]] %in% needed_models)
    if (nrow(model_out_tbl) == 0) {
      message(
        "None of the requested model(s) have forecasts for target '", target_id,
        "' in evaluation set '", eval_set$eval_set_name, "'. Skipping."
      )
      next
    }
    missing_requested <- setdiff(model_ids, unique(model_out_tbl$model_id))
    if (length(missing_requested) > 0) {
      message(
        "Note: model(s) ", paste(missing_requested, collapse = ", "),
        " have no forecasts for target '", target_id, "', eval_set '",
        eval_set$eval_set_name, "'."
      )
    }

    by <- by_arg

    hubPredEvalsData:::get_and_save_scores(
      model_out_tbl = model_out_tbl,
      oracle_output = oracle_output_t,
      metric_name_to_output_type = metric_name_to_output_type,
      relative_metrics = relative_metrics,
      baseline = baseline,
      target_id = target_id,
      eval_set_name = eval_set$eval_set_name,
      by = by,
      out_path = out_path,
      transform = transform,
      task_groups_w_target = task_groups_w_target
    )

    scores_dir <- file.path(out_path, target_id, eval_set$eval_set_name)
    if (!is.null(by)) {
      scores_dir <- file.path(scores_dir, by)
    }
    scores <- utils::read.csv(file.path(scores_dir, "scores.csv"))
    scores_display <- scores[scores$model_id %in% model_ids, , drop = FALSE]

    cat(
      "\n=== ", target_id, " | ", eval_set$eval_set_name,
      if (!is.null(by)) paste0(" | by: ", by) else "",
      " ===\n",
      sep = ""
    )
    print(scores_display, row.names = FALSE)
  }
}

if (!write_to_disk) {
  unlink(out_path, recursive = TRUE)
}
