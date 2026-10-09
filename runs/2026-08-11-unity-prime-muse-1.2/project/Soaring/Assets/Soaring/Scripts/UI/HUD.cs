
using UnityEngine;
using UnityEngine.UI;
using TMPro;

namespace Soaring.UI
{
    public class HUD : MonoBehaviour
    {
        public TextMeshProUGUI sizeText;
        public TextMeshProUGUI speedText;
        public TextMeshProUGUI statusText;
        public Image vignette;
        public Soaring.Flight.BirdFlightController flight;
        public Soaring.GameLoop.BirdGrowth growth;

        void Awake()
        {
            if (!flight) flight = FindFirstObjectByType<Soaring.Flight.BirdFlightController>();
            if (!growth) growth = flight ? flight.GetComponent<Soaring.GameLoop.BirdGrowth>() : null;
            if (!flight && Camera.main) flight = FindFirstObjectByType<Soaring.Flight.BirdFlightController>();
        }

        void Update()
        {
            if (flight)
            {
                if (speedText) speedText.text = $"{flight.Speed:F1} m/s {(flight.IsPerched? "(Perched - flap hard to launch!)":"")}";
                if (vignette) { var c=vignette.color; c.a = Mathf.Clamp01(Mathf.InverseLerp(12f, 26f, flight.Speed)*0.55f); vignette.color=c; }
            }
            if (growth && sizeText) sizeText.text = $"Size {growth.CurrentScale:F2}x";
            if (statusText && flight)
            {
                string tip = "";
                if (flight.Speed < 3f && !flight.IsPerched) tip = "Flap DOWN hard with both wings - like a bird!";
                else if (flight.IsPerched) tip = "On perch. Strong FLAP to take off.";
                else tip = $"Tilt wings to turn  •  Pitch up to brake  •  Streamline wings to glide";
                statusText.text = tip;
            }
        }
    }
}
