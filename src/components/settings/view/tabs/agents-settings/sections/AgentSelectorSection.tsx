import { PillBar, Pill } from '../../../../../../shared/view/ui';
import SessionProviderLogo from '../../../../../llm-logo-provider/SessionProviderLogo';
import type { AgentSelectorSectionProps } from '../types';

export default function AgentSelectorSection({
  agents,
  selectedAgent,
  onSelectAgent,
  agentContextById,
}: AgentSelectorSectionProps) {
  return (
    <div className="flex-shrink-0 border-b border-border px-3 py-2 md:px-4 md:py-3">
      <PillBar className="w-full md:w-auto">
        {agents.map((agent) => (
          <Pill
            key={agent}
            isActive={selectedAgent === agent}
            onClick={() => onSelectAgent(agent)}
            className="min-w-0 flex-1 justify-center md:flex-initial"
          >
            <SessionProviderLogo provider={agent} className="h-4 w-4 flex-shrink-0" />
            <span className="truncate">Claude</span>
            {agentContextById[agent].authStatus.authenticated && (
              <span className="h-1.5 w-1.5 flex-shrink-0 rounded-full bg-blue-500" />
            )}
          </Pill>
        ))}
      </PillBar>
    </div>
  );
}
