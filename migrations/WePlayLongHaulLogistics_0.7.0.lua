-- Recipes moved behind research: refresh unlocks for existing saves.
for _, force in pairs(game.forces) do
  force.reset_technology_effects()
end
