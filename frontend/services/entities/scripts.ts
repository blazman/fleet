import sendRequest from "services";
import endpoints from "utilities/endpoints";

export interface IScriptResult {
  host_id: number;
  execution_id: number;
  script_contents: string;
  exit_code: number | null;
  output: string;
  message: string;
  runtime: number;
  host_timeout: boolean;
}

export default {
  getScriptResult(id: number) {
    const { SCRIPT_RESULT } = endpoints;

    // TODO: uncomment when API is ready.
    // return sendRequest("GET", SCRIPT_RESULT(id));
    return new Promise((resolve) => {
      resolve({
        host_id: 1,
        execution_id: 1,
        script_contents: "test contentsss here is here",
        exit_code: 0,
        output: "test output",
        message: "test message",
        runtime: 20,
        host_timeout: false,
      });
    });
  },
};
