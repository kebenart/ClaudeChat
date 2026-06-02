export const runningSessionsService = {
  list(getActiveIds: () => string[]): string[] {
    const result = getActiveIds();
    return Array.isArray(result) ? result : [];
  },
};
