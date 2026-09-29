import type { BurnBarCatalog, BurnBarHealthResponse, OpenBurnBarState } from "../../src/types";
import type { BurnBarWorkspaceCapabilities } from "../../src/workspace/types";

interface ReplayStepResult<T> {
  result: T;
}

interface ReplayStepError {
  error: string;
}

export type ReplayStep<T> = ReplayStepResult<T> | ReplayStepError;

interface ReplayAction {
  type: "refresh" | "repair";
  label: string;
}

export interface ReplayScenario {
  name: string;
  daemon: {
    health: ReplayStep<BurnBarHealthResponse>[];
    catalog?: ReplayStep<BurnBarCatalog>[];
  };
  workspace: {
    capabilities: ReplayStep<BurnBarWorkspaceCapabilities>[];
  };
  repair?: ReplayStep<{
    message: string;
  }>;
  actions: ReplayAction[];
}

interface ReplayCheckpoint {
  label: string;
  snapshot: OpenBurnBarState;
  healthRows: Array<{
    id: string;
    label: string;
    value: string;
    icon: "pass" | "warning" | "pulse" | "note";
    tooltip?: string;
  }>;
  runDetailRows: Array<{
    id: string;
    label: string;
    value: string;
  }>;
  actionResult?: {
    message: string;
  };
}

export interface ReplayEvaluation {
  name: string;
  checkpoints: ReplayCheckpoint[];
}
