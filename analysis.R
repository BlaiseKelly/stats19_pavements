library(sf)
library(dplyr)
library(stats19)
library(bbplot)
library(ggplot2)
library(treemapify)

source("R/summary.R")

# define the year range of analysis
base_year = 2020
upper_year = 2024

# import crashes and trim to temporal parameters and make spatial
crashes_gb = get_stats19("5 years", type = "collision") |> 
  filter(collision_year >= base_year & collision_year <= upper_year) |> 
  format_sf()

# import vehicles and use c index from crashes
vehicles_gb = get_stats19("5 years", type = "vehicle")|> 
  mutate(vehicle_type = if_else(escooter_flag == "Vehicle was an e-scooter", "e-scooter", vehicle_type)) # add in escooters

# e scooter collisions from vehicle description
e_scooter_collisions = filter(vehicles_gb, vehicle_type == "e-scooter")

# for age breaks as those in the data don't match the dft factsheets
dft_breaks = c(0, 11, 15, 19, 24, 29, 39, 49, 59, 69, 100)
dft_labels = c("0-11", "12-15", "16-19", "20-24", "25-29",
               "30-39", "40-49", "50-59", "60-69", "70+")

# import casualties, add fatal column to match serious and slight and include e-scooters from vehicle data, add in dft age bands (different to those included in data)
casualties_gb = get_stats19("5 years", type = "casualty")|> 
  mutate(fatal_count = if_else(casualty_severity == "Fatal", 1, 0)) |>  # there is a column for serious and slight, so add one for fatal to make analysis consistent
  mutate(
    casualty_type = ifelse(
      collision_index %in% e_scooter_collisions$collision_index & # add e_scooters
        casualty_type == "Data missing or out of range",
      "E-scooter rider",
      casualty_type
    )) |> 
  dplyr::mutate(dft_age_band = cut(as.numeric(age_of_casualty),
                                   breaks = dft_breaks, labels = dft_labels))

# casuatlies catagorised as on footway or verge https://assets.publishing.service.gov.uk/media/6925a35433d088f6d5da2cf0/STATS20_2024_specification.pdf
casualties_pv_summary = casualties_gb |> 
  filter(pedestrian_location == "On footway or verge") |> 
  summarise_casualties_per_collision() # summarise casualties to one line per collision

# summarise vehicle classes using function and then summarise to a category, large,high powered vehicle (Car/Motorbike/Taxi/Bus/Goods vehicle) or 'micro mobility/bicycle'
vehicles_categorised = vehicles_gb |> 
  filter(collision_index %in% casualties_pv$collision_index) |> 
  summarise_vehicle_types("short_name") |> 
  mutate(vehicle_cat = ifelse(is.na(short_name) | short_name == "Other vehicle","unknown",short_name)) |> 
  mutate(vehicle_cat = ifelse(short_name %in% c("Pedal cycle", "e-scooter","Mobility scooter")|short_name == "unknown","Bicycle/E-scooter/Mobility Scooter","Motor vehicle")) |> 
  select(collision_index,vehicle_type, short_name,vehicle_cat)

# only single vehicle collisions can be confident of the vehicle that hit the pedestrian
single_vehicle_pavement <- crashes_gb |> 
  filter(number_of_vehicles == 1 & collision_year >= base_year & collision_year <= upper_year) |> 
  inner_join(vehicles_categorised) |> 
  inner_join(casualties_pv_summary) |> 
  filter(Fatal > 0)

#Make plot
p1 = ggplot(single_vehicle_pavement, aes(x = collision_year, y = Fatal, fill = vehicle_cat)) +
  geom_bar(stat="identity", 
           position="stack") +
  scale_fill_manual(values = c("#FAAB18", "#1380A1")) +
  labs(title="Pedestrian pavement fatalities",
       subtitle = "Between 2020 and 2024 by vehicle category")+
  bbc_style()

dir.create("plots/")

# write out
finalise_plot(plot_name = p1, source_name = "Source: STATS19",save_filepath = "plots/pavement_fatalities.png")

# Where did they happen?

# MSOAs have a consistent size and are also can be joined with meaningful names https://houseofcommonslibrary.github.io/msoanames/
# read in meaningful msoa names
msoa_names = read.csv("https://houseofcommonslibrary.github.io/msoanames/MSOA-Names-2.2.csv")

# read in msoa shape files (from github as ons requires manual download)
msoa_geo = st_read("https://github.com/BlaiseKelly/stats19_stats/releases/download/msoa_boundaries-v1.0/msoa.gpkg") |> 
  st_transform(27700) |> 
  left_join(msoa_names, by = c("MSOA21CD" = "msoa21cd")) |> 
  select(msoa21hclnm,localauthorityname,geom)

# single vehicle pavement collisions joined with msoa geometry and summarised
svp_msoa = single_vehicle_pavement |> 
  st_join(msoa_geo) |> 
  st_set_geometry(NULL) |> 
  group_by(msoa21hclnm,localauthorityname) |> 
  summarise(across(c("Fatal", "Serious", "Slight"),sum)) |> 
  filter(!is.na(msoa21hclnm)) |> 
  rowwise() |> 
  mutate(ksi = sum(Fatal,Serious),
         total = sum(Fatal,Serious,Slight)) 

# same for local authorities
svp_la = svp_msoa |> 
  group_by(localauthorityname) |> 
  summarise(across(c("Fatal", "Serious", "Slight"),sum))

# there are a lot of places with 1, so just plot >1. Join LA to give more context
svp_msoa_plot = svp_msoa |> 
  filter(Fatal>1) |> 
  mutate(msoa_la = paste0(msoa21hclnm,"\n",localauthorityname))

# treeplot
p2 = ggplot(svp_msoa_plot, aes(area = Fatal, fill = as.factor(Fatal), label = msoa_la)) +
  geom_treemap() +
  geom_treemap_text(colour = "white")+
  scale_fill_manual(values = c("#13809f","#9a1101"))+
  labs(title="Pedestrian pavement fatalities",
       subtitle = "MSOA regions with more than 1 death between 2020 and 2024")+
  bbc_style()+
  theme(legend.position = "bottom")

# write out
finalise_plot(plot_name = p2, source_name = "Source: STATS19",save_filepath = "plots/pavement_fatalities_msoa.png")

svp_la_plot = svp_la |> 
  filter(Fatal>1) 

# treeplot
p3 = ggplot(svp_la_plot, aes(area = Fatal, fill = as.factor(Fatal), label = localauthorityname)) +
  geom_treemap() +
  geom_treemap_text(colour = "white")+
  scale_fill_manual(values = c("#13809f","#9a1101"))+
  labs(title="Pedestrian pavement fatalities",
       subtitle = "Local Authorities with more than 1 death between 2020 and 2024")+
  bbc_style()+
  theme(legend.position = "bottom")

# write out
finalise_plot(plot_name = p3, source_name = "Source: STATS19",save_filepath = "plots/pavement_fatalities_la.png")

# some other plots on casualty data

# group by casualty imd
cas_pv_imd = casualties_gb |> 
  filter(pedestrian_location == "On footway or verge") |> 
  group_by(casualty_imd_decile) |> 
  summarise(Fatal = sum(fatal_count)) 

#Make plot
p4 = ggplot(cas_pv_imd, aes(x = casualty_imd_decile, y = Fatal)) +
  geom_bar(stat="identity",
           show.legend = FALSE,
           position="identity",
           fill = "#9a1101")+
  labs(title="Pedestrian pavement fatalities",
       subtitle = "Between 2020 and 2024 by IMD (index of multiple deprevation)")+
  bbc_style()+
  coord_flip()+
  theme(panel.grid.major.x = element_line(color="#cbcbcb", alpha - 0.1), 
        panel.grid.major.y=element_blank())

finalise_plot(plot_name = p4, source_name = "Source: STATS19",height_pixels = 800,width_pixels = 700, save_filepath = "plots/pavement_fatalities_imd.png")

# group by casualty age 
cas_pv_age = casualties_gb |> 
  filter(pedestrian_location == "On footway or verge") |> 
  group_by(dft_age_band) |> 
  summarise(Fatal = sum(fatal_count)) 

#Make plot
p5 = ggplot(cas_pv_age, aes(x = dft_age_band, y = Fatal)) +
  geom_bar(stat="identity",
           show.legend = FALSE,
           position="identity",
           fill="#1380A1")+
  labs(title="Pedestrian pavement fatalities",
       subtitle = "Between 2020 and 2024 by age")+
  bbc_style()+
  coord_flip()+
  theme(panel.grid.major.x = element_line(color="#cbcbcb", alpha - 0.1), 
        panel.grid.major.y=element_blank())

finalise_plot(plot_name = p5, source_name = "Source: STATS19",height_pixels = 600, save_filepath = "plots/pavement_fatalities_age.png")
